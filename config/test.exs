import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :agent_on_demand, AgentOnDemand.Repo,
  database: Path.expand("../agent_on_demand_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :agent_on_demand, AgentOnDemandWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "c4S1HEBb+LhhInAgMbEJdXVBSKK65S7Mk9oeXrPTn65slnwVQU5zFqCT3p2wqWaR",
  server: false

# Don't rehydrate ConversationServers in tests — they'd hit the real
# Sprites API. Tests start servers explicitly with mocked sprites.
config :agent_on_demand, :skip_rehydrate, true

# Disable async checkpoint creation in tests; the Task can outlive the
# test process and try to update the DB after the Ecto sandbox has been
# released.
config :agent_on_demand, :checkpoint_creation_enabled, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
