import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :factory, Factory.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "factory_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :factory, FactoryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "BNExue6TRKovACudS5vCocp7u/Hcdi2ehPFnNVu79vdzsqZlzPGZUjwnVj9QUrFp",
  server: false

# In test we don't send emails
config :factory, Factory.Mailer, adapter: Swoosh.Adapters.Test

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

# Tests talk to a fake kiro-cli instead of the real one.
config :factory, :kiro,
  cli: Path.expand("../test/support/fake_kiro.mjs", __DIR__),
  workspace: Path.expand("../tmp/test-workspace", __DIR__),
  log_dir: Path.expand("../tmp/test-kiro-logs", __DIR__),
  prompt_timeout: 5_000,
  # The fake kiro-cli never says its tools are there.
  mcp_ready_timeout: 200

# Repositories added as data sources are cloned here in tests.
config :factory, :sources_dir, Path.expand("../tmp/test-sources", __DIR__)

# Actions' HTTP requests (GitHub, Azure DevOps, webhooks, API calls) go to a stub.
config :factory, :actions_req_options, plug: {Req.Test, Factory.Actions}

# Runs don't execute on their own in tests; tests call Factory.Engine.run/1.
config :factory, :run_engine, false
config :factory, :reset_on_boot, false

# Kiro doesn't retitle chats in the background in tests; see Factory.Runs.TitlesTest.
config :factory, :auto_titles, false

# Tests don't ask the real Kiro which models it has.
config :factory, :check_kiro_models, false
