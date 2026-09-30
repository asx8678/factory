# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :factory,
  ecto_repos: [Factory.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :factory, FactoryWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FactoryWeb.ErrorHTML, json: FactoryWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Factory.PubSub,
  live_view: [signing_salt: "ftYdf3ib"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :factory, Factory.Mailer, adapter: Swoosh.Adapters.Local

# Kiro agents run `kiro-cli acp --agent-engine v3` in this folder unless the agent sets its own.
# Their stderr goes to tmp/kiro-logs/agent-<id>.log.
config :factory, :kiro,
  cli: System.find_executable("kiro-cli") || Path.expand("~/.local/bin/kiro-cli"),
  workspace: Path.expand("../tmp/workspace", __DIR__),
  log_dir: Path.expand("../tmp/kiro-logs", __DIR__),
  prompt_timeout: :timer.minutes(10)

# Deterministic context management (Factory.Context). A Kiro session compacts before its
# next message once its context is this full (Kiro's own summarizer starts at 80%); the
# latest messages stay word for word within keep_recent_tokens. A run step's prompt is
# kept within run_prompt_bytes.
config :factory, :context,
  compact_at: 70,
  keep_recent_tokens: 20_000,
  run_prompt_bytes: 256 * 1024

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  factory: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Log files can be attached in the chat (troubleshooting keeps them as evidence).
config :mime, :types, %{"text/x-log" => ["log"]}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
