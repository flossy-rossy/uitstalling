# Deploying UIT (uitstalling) to Fly.io + Neon

Storage is external Postgres (Neon), so Fly runs a single stateless app machine.

## 1. Neon database (once)

Create a project at neon.tech, copy the pooled connection string. It looks like:

    postgresql://user:pass@ep-xxx-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require

Keep `sslmode=require` — `config/runtime.exs` also sets `ssl: [verify: :verify_none]`.

## 2. Fly app (once)

    fly apps create uitstalling --org personal

**The org is decided only here** — every later command (`deploy`, `secrets`,
`storage`, `certs`) targets the app from `fly.toml` and inherits its org, so
a CLI whose default org is elsewhere doesn't matter after this line.

`primary_region = 'jnb'` (Johannesburg) is set for SA latency; change if Neon is
in another region and you'd rather co-locate.

## 2b. Custom domain (uitstalling.co.za)

`PHX_HOST` in fly.toml is already the custom domain (= WebAuthn RP id — do
not enroll passkeys until you're browsing via it). After the first deploy:

    fly ips allocate-v4 --shared
    fly ips allocate-v6
    fly ips list

At the DNS host for uitstalling.co.za:

    A     @    <the v4 from `fly ips list`>
    AAAA  @    <the v6 from `fly ips list`>

Then:

    fly certs add uitstalling.co.za
    fly certs check uitstalling.co.za    # repeat until it reports issued

Optional www: `fly certs add www.uitstalling.co.za` + a CNAME
`www → uitstalling.fly.dev`.

## 3. Object storage — REQUIRED for images (once)

    fly storage create --public

This provisions a Tigris bucket and injects `BUCKET_NAME` + `AWS_*` secrets
automatically; `config/runtime.exs` switches asset storage to S3 when it sees
them. Two things that bite if skipped:

- **No bucket = silent data loss.** Without `BUCKET_NAME`, uploads and
  generated images fall back to the machine's local disk, which is EPHEMERAL
  on Fly — every deploy/restart deletes them, with no error.
- **`--public` is load-bearing.** `/a/:asset_id` serves by 302-redirecting to
  the public bucket URL (the 512mb machine never proxies image bytes). A
  private bucket would 403 every image; switch to presigned URLs before
  making the bucket private.

## 4. Secrets

    fly secrets set \
      SECRET_KEY_BASE="$(mix phx.gen.secret)" \
      DATABASE_URL="postgresql://...neon.../neondb?sslmode=require" \
      AGENT_API_KEY="sk-or-..." \
      AGENT_API_FORMAT="openai" \
      AGENT_BASE_URL="https://openrouter.ai/api/v1" \
      AGENT_MODEL="z-ai/glm-4.6" \
      IMAGE_MODEL="bytedance-seed/seedream-4.5" \
      AUTHOR_EMAILS="REDACTED,partner@example.com"

Notes:
- `AUTHOR_EMAILS` (comma-separated) is the closed-beta allowlist — only these
  can register a passkey and author. Empty = open registration.
- For Anthropic/Z.ai instead of OpenRouter: drop `AGENT_API_FORMAT` (defaults
  `anthropic`) and set `AGENT_BASE_URL`/`AGENT_MODEL` accordingly.
- **Image generation** goes through OpenRouter's Image API regardless of the
  text-agent format. `IMAGE_API_KEY` is only needed when `AGENT_API_KEY`
  isn't an OpenRouter key; `IMAGE_MODEL` must be an *image* model (Seedream,
  FLUX...) — ByteDance's `seedance-*` slugs are the VIDEO family and will
  fail on `/v1/images`. `IMAGE_BASE_URL` defaults to OpenRouter.
- `PHX_HOST`/`PHX_SERVER`/`PORT` are non-secret and already in `fly.toml`.
  `PHX_HOST` doubles as the WebAuthn RP id — set it to your final domain
  before enrolling people (passkeys are bound to the host).

## 5. Deploy

    fly deploy

The release runs `/app/bin/migrate` first (creates the tables on Neon —
including `assets`).

## 6. Seed the demo deck (optional)

    fly ssh console -C "/app/bin/uitstalling eval 'Code.eval_file(\"priv/repo/seeds.exs\")'"

Or just create a deck through the UI — `/` → Sign in → New presentation.

## Health

- `min_machines_running = 1` keeps the per-deck workers (and their queued
  generations) alive. `auto_stop_machines = 'stop'` still scales extra
  machines down. On boot the app sweeps requests a previous run left
  in-flight (marked failed, visible in the deck's failure banner) and
  re-drains anything still pending.
- Generation failures/retries: transport errors and 429/5xx/529 retry
  automatically (up to 2 retries); timeouts fail visibly and are cancellable
  from the deck's editing bar.
- 512mb is comfortable for this single-purpose Phoenix app.
