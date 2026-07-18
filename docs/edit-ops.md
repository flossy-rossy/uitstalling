# Edit Operations — the one-page contract

Status: **spec** (pre-implementation). This document is the single source of
truth for the ops pivot: the validator, the model prompt/JSON Schema, the
channel protocol for future multi-user editing, and the edit timeline are all
generated from or checked against it.

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

## The vocabulary

An **op batch** is what one agent call or one user action produces: a list of
ops plus a precondition.

```json
{
  "base": "<slide content hash the ops were computed against>",
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
4. **Timeline**: every applied batch is appended to an edit log
   (request id, actor user|agent, base, ops, resulting hash). Undo becomes
   "apply the inverse batch"; multi-user joins replay the log.

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
