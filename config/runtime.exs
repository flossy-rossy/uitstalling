import Config

# Generation agent — provider-agnostic on purpose: the API key only
# authenticates; the model is a per-request parameter, so all three are
# swappable without code changes. Never read in test: a test run must be
# hermetic, not inherit whatever AGENT_*/IMAGE_* the host shell exports
# (config/test.exs pins the test values).
if config_env() != :test do
  config :uitstalling,
    agent_api_key: System.get_env("AGENT_API_KEY"),
    agent_model: System.get_env("AGENT_MODEL") || "claude-haiku-4-5",
    agent_base_url: System.get_env("AGENT_BASE_URL") || "https://api.anthropic.com",
    agent_app_url: System.get_env("AGENT_APP_URL")

  # Image generation (OpenRouter's unified Image API). IMAGE_API_KEY may be
  # omitted when AGENT_API_KEY is already an OpenRouter key.
  config :uitstalling,
    image_api_key: System.get_env("IMAGE_API_KEY"),
    image_model: System.get_env("IMAGE_MODEL") || "bytedance-seed/seedream-4.5",
    image_base_url: System.get_env("IMAGE_BASE_URL") || "https://openrouter.ai/api/v1"
end

# Asset storage: Tigris (Fly's S3) when a bucket is configured —
# `fly storage create` injects BUCKET_NAME + AWS_* into the app env.
# Without one (dev/test, or a fresh deploy before storage exists), assets
# fall back to local disk, which on Fly is EPHEMERAL — create the bucket
# before relying on uploads in production.
if bucket = System.get_env("BUCKET_NAME") do
  config :uitstalling, :asset_storage,
    adapter: :s3,
    bucket: bucket,
    endpoint: System.get_env("AWS_ENDPOINT_URL_S3") || "https://fly.storage.tigris.dev",
    region: System.get_env("AWS_REGION") || "auto",
    access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY")
end

# Headless Chrome for PDF export — on demand, so Chrome only runs while a
# deck is being printed. CHROME_EXECUTABLE overrides discovery (set in the
# Docker image); CHROME_NO_SANDBOX is needed there too, since the container
# runs Chrome as an unprivileged user without userns. Not configured in
# test: the supervisor child is skipped and Decks.Pdf is stubbed by a fake.
if config_env() != :test do
  config :uitstalling,
         :chromic_pdf,
         Enum.reject(
           [
             on_demand: true,
             # checkout_timeout must absorb the on-demand cold start (Chrome
             # boot + first page) — the 5s default 500s the first download.
             # init_timeout likewise: a shared-CPU Fly machine can take >5s
             # just to spawn the session.
             session_pool: [size: 1, checkout_timeout: 60_000, init_timeout: 30_000],
             # Containers give /dev/shm ~64MB and Chrome crashes its tab
             # without this ('Inspector.targetCrashed' on Fly) — render via
             # /tmp instead. Harmless outside containers.
             chrome_args: "--disable-dev-shm-usage",
             chrome_executable: System.get_env("CHROME_EXECUTABLE"),
             no_sandbox: System.get_env("CHROME_NO_SANDBOX") in ~w(true 1)
           ],
           fn {_key, value} -> value in [nil, false] end
         )
end

# Wire format: "anthropic" (default; also Z.ai's GLM endpoint) or "openai"
# (OpenRouter and most aggregators). Tests pin the Fake agent in test.exs.
if config_env() != :test do
  deck_agent =
    case System.get_env("AGENT_API_FORMAT", "anthropic") do
      "openai" -> Uitstalling.Decks.Agent.OpenAI
      _ -> Uitstalling.Decks.Agent.Claude
    end

  config :uitstalling, deck_agent: deck_agent
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/uitstalling start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :uitstalling, UitstallingWeb.Endpoint, server: true
end

config :uitstalling, UitstallingWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :uitstalling, UitstallingWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/uitstalling_web/router\.ex$"E,
        ~r"lib/uitstalling_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :uitstalling, Uitstalling.Repo,
    # Neon (and most managed Postgres) require TLS. verify_none keeps the first
    # deploy simple; tighten to CA verification later if desired.
    ssl: [verify: :verify_none],
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :uitstalling, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # WebAuthn RP is the deployed host; AUTHOR_EMAILS (comma-separated) is the
  # closed-beta allowlist. Empty AUTHOR_EMAILS = open registration.
  config :uitstalling, :webauthn,
    rp_id: host,
    origin: "https://#{host}",
    rp_name: System.get_env("RP_NAME") || "uitstalling"

  config :uitstalling,
    allowed_emails:
      (System.get_env("AUTHOR_EMAILS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

  config :uitstalling, UitstallingWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # LiveView websockets check the browser's Origin against this list; with
    # only PHX_HOST allowed, visiting via the fly.dev URL loads the page but
    # never connects the socket (the "stuck loading bar"). Allow both — the
    # fly.dev host stays view-only anyway since passkeys bind to PHX_HOST.
    check_origin: ["https://#{host}", "https://uitstalling.fly.dev"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :uitstalling, UitstallingWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :uitstalling, UitstallingWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :uitstalling, Uitstalling.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
