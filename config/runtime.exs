import Config

# Load a local .env file in dev/test for convenience. Existing System env
# wins, so this only fills in unset vars.
env_path = Path.join(File.cwd!(), ".env")

if config_env() != :prod and File.exists?(env_path) do
  env_path
  |> File.stream!()
  |> Enum.each(fn line ->
    line = String.trim(line)

    cond do
      line == "" ->
        :ok

      String.starts_with?(line, "#") ->
        :ok

      true ->
        case String.split(line, "=", parts: 2) do
          [k, v] ->
            v = v |> String.trim() |> String.trim_leading("\"") |> String.trim_trailing("\"")
            if System.get_env(k) in [nil, ""], do: System.put_env(k, v)

          _ ->
            :ok
        end
    end
  end)
end

# config/runtime.exs runs on every release startup, including for
# CLI subcommands like `./aod conv list` or `./aod up`. We only want
# to enforce server-only env requirements (ADMIN_TOKEN, SECRETS_KEY,
# DATABASE_PATH, ...) when actually starting Phoenix. The signal is
# `PHX_SERVER` — set in `start.sh` for sprite deployments, absent
# for CLI mode.
server? = System.get_env("PHX_SERVER") in ~w(1 true yes)

if server? do
  config :agent_on_demand, AgentOnDemandWeb.Endpoint, server: true
end

config :agent_on_demand, AgentOnDemandWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

env = config_env()

# Single-tenant admin token. Required for the server; CLI mode reads
# AOD_TOKEN directly from the env when talking to a remote AoD, so
# this config is unused there.
admin_token =
  case {System.get_env("ADMIN_TOKEN"), env, server?} do
    {nil, :prod, true} -> raise "environment variable ADMIN_TOKEN is missing."
    {nil, _, _} -> "dev-admin-token"
    {value, _, _} -> value
  end

config :agent_on_demand, :admin_token, admin_token

# 32-byte symmetric key for secret-at-rest encryption. Required for
# the server; unused in CLI mode (no DB, no decryption).
secrets_key =
  case {System.get_env("SECRETS_KEY"), env, server?} do
    {nil, :prod, true} ->
      raise "environment variable SECRETS_KEY is missing (32 bytes, base64-encoded)."

    {nil, _, _} ->
      :crypto.hash(:sha256, "agent_on_demand:dev:secrets_key")

    {encoded, _, _} ->
      case Base.url_decode64(encoded, padding: false) do
        {:ok, <<_::binary-32>> = key} -> key
        _ -> raise "SECRETS_KEY must be 32 bytes encoded as url-safe base64 (no padding)."
      end
  end

config :agent_on_demand, :secrets_key, secrets_key

config :agent_on_demand, :sprites_token, System.get_env("SPRITES_TOKEN")
config :agent_on_demand, :anthropic_api_key, System.get_env("ANTHROPIC_API_KEY")

# Multi-node clustering. Default: no clustering (empty topology — single
# node). To enable on Render set CLUSTER_DNS_QUERY to the internal DNS
# name of the service (e.g. `agent-on-demand` for `agent-on-demand.flycast`
# or whatever the platform exposes); libcluster's DNSPoll strategy will
# discover peer nodes by polling the DNS record. Erlang Distribution
# also requires RELEASE_COOKIE and matching node names — Render's elixir
# runtime sets these for you when the release boots.
cluster_topologies =
  case System.get_env("CLUSTER_DNS_QUERY") do
    nil ->
      []

    "" ->
      []

    query ->
      [
        aod: [
          strategy: Cluster.Strategy.DNSPoll,
          config: [
            polling_interval: 5_000,
            query: query,
            node_basename: System.get_env("RELEASE_NAME", "agent_on_demand")
          ]
        ]
      ]
  end

config :libcluster, topologies: cluster_topologies
config :agent_on_demand, :claude_code_oauth_token, System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
config :agent_on_demand, :openai_api_key, System.get_env("OPENAI_API_KEY")
config :agent_on_demand, :gemini_api_key, System.get_env("GEMINI_API_KEY")

# Public URL of this AoD instance. Sprites use it (via the bundled "aod"
# skill) to fan out to more conversations. Must be reachable from inside
# the sprite's network — i.e. a public URL or a tunnel.
config :agent_on_demand, :public_url, System.get_env("AOD_PUBLIC_URL")

if config_env() == :prod and server? do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/agent_on_demand/agent_on_demand.db
      """

  config :agent_on_demand, AgentOnDemand.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

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

  config :agent_on_demand, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :agent_on_demand, AgentOnDemandWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :agent_on_demand, AgentOnDemandWeb.Endpoint,
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
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :agent_on_demand, AgentOnDemandWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
