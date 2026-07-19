import Config

# Tests use the DB sandbox; the fake agent stands in for the model, and the
# pipeline is started manually by the tests that need it.
config :uitstalling,
  deck_agent: Uitstalling.Decks.Agent.Fake,
  start_pipeline: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :uitstalling, Uitstalling.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "uitstalling_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :uitstalling, UitstallingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "KzFS9N0HXNeCpmgX7LHD3W28RR1EXpVcygLQagLHtd4t3JFzyoYW9wFiF5bI2tn6",
  server: false

# In test we don't send emails
config :uitstalling, Uitstalling.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :uitstalling, :webauthn,
  rp_id: "localhost",
  origin: "http://localhost:4000",
  rp_name: "uitstalling"

# Empty allowlist in tests = open (fixtures create registered users freely).
config :uitstalling, allowed_emails: []

# Asset uploads land in a throwaway dir; tests clean it themselves.
config :uitstalling, :asset_storage, adapter: :local, dir: "tmp/test-uploads"

# Deterministic image generator for tests.
config :uitstalling, :image_generator, Uitstalling.Assets.Generator.Fake

# Short generation timeout so hang-handling is testable.
config :uitstalling, :image_gen_timeout, 500

# Provider HTTP goes through a Req.Test plug (any unstubbed call fails
# loudly) with zero retry backoff so retry tests run instantly.
config :uitstalling, :req_options,
  plug: {Req.Test, Uitstalling.ProviderStub},
  retry_delay: 0
