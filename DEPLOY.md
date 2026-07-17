# Deploying UIT (uitstalling) to Fly.io + Neon

Storage is external Postgres (Neon), so Fly runs a single stateless app machine.

## 1. Neon database (once)

Create a project at neon.tech, copy the pooled connection string. It looks like:

    postgresql://user:pass@ep-xxx-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require

Keep `sslmode=require` — `config/runtime.exs` also sets `ssl: [verify: :verify_none]`.

## 2. Fly app (once)

    fly apps create uitstalling        # or `fly launch --no-deploy` and keep this fly.toml

`primary_region = 'jnb'` (Johannesburg) is set for SA latency; change if Neon is
in another region and you'd rather co-locate.

## 3. Secrets

    fly secrets set \
      SECRET_KEY_BASE="$(mix phx.gen.secret)" \
      DATABASE_URL="postgresql://...neon.../neondb?sslmode=require" \
      AGENT_API_KEY="sk-or-..." \
      AGENT_API_FORMAT="openai" \
      AGENT_BASE_URL="https://openrouter.ai/api/v1" \
      AGENT_MODEL="z-ai/glm-4.6" \
      AUTHOR_EMAILS="REDACTED,partner@example.com"

Notes:
- `AUTHOR_EMAILS` (comma-separated) is the closed-beta allowlist — only these
  can register a passkey and author. Empty = open registration.
- For Anthropic/Z.ai instead of OpenRouter: drop `AGENT_API_FORMAT` (defaults
  `anthropic`) and set `AGENT_BASE_URL`/`AGENT_MODEL` accordingly.
- `PHX_HOST`/`PHX_SERVER`/`PORT` are non-secret and already in `fly.toml`.
  `PHX_HOST` doubles as the WebAuthn RP id — set it to your final domain
  before enrolling people (passkeys are bound to the host).

## 4. Deploy

    fly deploy

The release runs `/app/bin/migrate` first (creates the tables on Neon).

## 5. Seed the demo deck (optional)

    fly ssh console -C "/app/bin/uitstalling eval 'Code.eval_file(\"priv/repo/seeds.exs\")'"

Or just create a deck through the UI — `/` → Sign in → New presentation.

## Health

- `min_machines_running = 1` keeps the pipeline GenServer alive to drain the
  edit queue. `auto_stop_machines = 'stop'` still scales extra machines down.
- 512mb is comfortable for this single-purpose Phoenix app.
