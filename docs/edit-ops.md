# Edit Operations — the one-page contract

Status: **steps 1–3 implemented** (part ids · `Uitstalling.Decks.Op`
parse/apply/invert · agent emits ops for block-scoped edits; whole-slide
replacement retained for rework). Still to come: grid arrangement, fan-out
with `base` preconditions, delta broadcasts, the edit-log table, channels.
This document is the single source of truth for the ops pivot: the
validator, the model prompt/JSON Schema, the channel protocol for future
multi-user editing, and the edit timeline are all generated from or checked
against it.

## Why ops

Today an agent edit returns the complete replacement JSON for a slide; the
pipeline wipes the slide and splices the new one in. Ops invert that: the
model (or a human client) emits a **description of the change**, and the app
applies it. Consequences, in order of importance:

1. Fields outside an op's target **cannot** change — scope enforcement by
   construction (the byte-diff block-scope guard becomes unnecessary).
2. Output tokens drop from a whole slide to ~tens of tokens per change.
   Output is 3–5× the price of input and never cacheable; input is ~90%
   discounted when cached. Fat cached context + minimal op output is the
   optimal request shape.
3. The edit is **data**: it can be logged (edit timeline), shown ("changed
   heading"), replayed, reverted individually, evaluated, and broadcast to
   other collaborators over PubSub/Channels.

## Addressing

Ops address **parts by stable id**, never by positional index. Prerequisites
(sequenced before ops ship):

- Every slide has a unique `id` (done — enforced by the validator, backfilled
  by `migrate/1`).
- Every part (list item or scalar-bearing region) gets a stable `id` at
  creation (`p0`, `p1`, … unique within the slide), assigned by the app —
  never by the model. `migrate/1` backfills them the same way it backfills
  slide ids.
- A slide's **arrangement** (later phase) is a named-cell grid — discrete
  cells like `r1c2`, validated against the layout, never free-form x/y
  coordinates. The renderer owns spacing/alignment; position is semantic
  data.

## Representation: structs inside, JSON at the boundary

Inside the app an op is an **Elixir struct, one module per op type**
(`Uitstalling.Decks.Op.SetField`, `Op.RemovePart`, …):

- The applicator is pattern-matched function heads
  (`def apply(%Op.SetField{} = op, raw)`) — same dispatch shape as the
  validator and renderer. Illegal ops are unrepresentable, not
  validated-away.
- Each op implements `invert(op, raw_before)` — undo becomes "apply the
  inverse batch" instead of whole-deck snapshots, which is also what makes
  per-user undo possible in multi-user editing.
- `@derive Jason.Encoder` on each struct covers the outbound wire
  (PubSub-to-client payloads, the edit-timeline API). Inbound, Jason only
  produces maps, so one `Op.parse/1` casts untrusted JSON (model replies via
  structured outputs, channel clients later) into structs or returns a
  per-op error — the single trust boundary for ops, the way `Decks.parse/1`
  is for documents. The model-facing JSON Schema and `Op.parse/1` derive
  from the same op definitions.

## The vocabulary

An **op batch** is what one agent call or one user action produces: a list of
ops plus a precondition. (Shown as wire JSON; in-app these are the structs
above.)

```json
{
  "base": "<deck seq the ops were computed against>",
  "ops": [
    {"op": "set_field",    "slide": "s3", "part": "p2", "field": "body", "value": "…"},
    {"op": "delete_field", "slide": "s3", "part": "p2", "field": "arrow_label"},
    {"op": "insert_part",  "slide": "s3", "list": "steps", "after": "p2", "part": {"id": "APP", "actor": "…", "body": "…"}},
    {"op": "remove_part",  "slide": "s3", "part": "p4"},
    {"op": "move_part",    "slide": "s3", "part": "p4", "after": "p1"},
    {"op": "replace_part", "slide": "s3", "part": "p2", "value": {"actor": "…", "body": "…"}},
    {"op": "set_slide_key", "slide": "s3", "key": "kicker", "value": "§ 2 · SCALE"}
  ]
}
```

Rules:

- `id` fields inside inserted parts are placeholders (`"APP"`); the app mints
  real ids on application. The model never invents ids.
- Slide-level scalars (`kicker`, `footnote`, `notes`, `tone`, `size`) use
  `set_slide_key` / `delete_slide_key` with the key validated against the
  design system, exactly as today.
- Layout changes and whole-slide rework stay on the existing
  whole-slide-replacement path — ops are for edits, regeneration is for
  rebuilds. `insert_slide` / `remove_slide` / `move_slide` are deck-level ops
  with the same shape, added when needed.

## Application semantics

1. **Precondition**: `base` must equal the current content hash of the slide
   (or the op batch is rejected with `:stale`, cheaply, before any model
   retry). This is what makes fan-out safe: N concurrent agent calls each
   target disjoint parts; the serial pipeline applies arriving batches in
   order; a batch whose target part vanished fails alone.
2. **Validation**: each op is checked for shape (unknown op, unknown field
   for the layout, bad enum → per-op error), then the ops are applied to a
   copy and the result must pass `Decks.parse/1`. Errors are returned in op
   terms ("op 2: steps requires actor") — the retry loop feeds them back with
   the rejected batch, same contract as today.
3. **Atomicity**: a batch applies entirely or not at all.
4. **Timeline — the deck IS an event log, materialized eagerly.** Every
   write appends one row to `deck_events`
   (`deck_id · seq · type · payload · actor · request_id? · inserted_at`)
   AND updates the deck's document row in the same transaction. Reads never
   fold — the doc row is the eagerly-materialized fold, and a test invariant
   asserts `fold(events) == doc` so fold drift is a CI failure, not silent
   data corruption. Event types: `deck.created` (prompt + choices),
   `deck.generated` (full-JSON snapshot — every deck's replay horizon starts
   here), `ops.applied` (the REALIZED batch from `apply_batch` — the batch,
   not the op, is the event: atomicity and undo are batch-level, and most
   batches are one op anyway), `slide.replaced` (whole-slide rework), and
   `deck.snapshot` (fallback for not-yet-op-shaped writes; also emitted
   before deploying op-schema changes so old shapes never need re-folding).
   The fold function stays dumb: apply event to doc — validation and
   migration remain at the write boundary. Undo = apply the inverse batch;
   forks and time-scrubbing = fold a prefix.
5. **Broadcast the delta**: `{:op_applied, batch, seq}` instead of
   `:deck_updated` — LiveViews apply it to in-memory state with no reload
   query, spinners key on the ops' targets. `seq` doubles as the `base`
   precondition (replacing content hashes): "computed against seq N" is the
   staleness check for fan-out and multi-user.
6. **The worker applies, it does not generate.** Generation — model calls,
   image providers — runs OFF the deck worker, concurrently; only the apply
   step serializes per deck (microseconds). An image generation submits its
   attach-op when the asset is ready, so images never block text edits and
   vice versa. This replaces the current blocking-generation DeckWorker
   behavior when ops land.

## Model contract

- Structured outputs (JSON Schema derived from this spec) on both clients;
  `op` is an enum, so an invalid op type is unrepresentable.
- The prompt carries the slide's parts WITH their ids so the model can name
  targets: the deck context block gains no weight, the response loses ~95%.
- App-managed keys (`image`, part `id`s, `v`) are never emitted by the model;
  the pipeline strips and re-attaches them defensively regardless.

## Sequencing

1. Part ids (`migrate/1` backfill + validator uniqueness) — independent, ship first.
2. Op vocabulary + applicator + tests (pure functions beside the existing
   mutation helpers, which they subsume).
3. Agent emits ops for block-scoped and small edits; whole-slide path retained
   for rework/layout changes.
4. Grid arrangement (named cells) + `move_part` across cells.
5. Fan-out: concurrent agent calls per part; serial application with `base`
   preconditions.
6. Channels/PubSub multi-user on top of the same op stream.
