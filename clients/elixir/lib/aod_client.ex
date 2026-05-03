defmodule AodClient do
  @moduledoc """
  Elixir client for the Agent on Demand API.

      client = AodClient.new(base_url: "https://aod.example.com", token: System.get_env("AOD_TOKEN"))

      {:ok, agents}  = AodClient.Agents.list(client)
      agent          = Enum.find(agents, & &1["name"] == "echo-bot")

      {:ok, conv}    = AodClient.Conversations.create(client, agent_id: agent["id"], prompt: "Say hi")
      {:ok, text}    = AodClient.Conversations.wait_for_result(client, conv["id"])
      IO.puts(text)

  Live streaming uses `AodClient.Conversations.stream/3` which returns a
  lazy `Stream` of parsed events.
  """

  defstruct [:base_url, :token, :req]

  @type t :: %__MODULE__{base_url: String.t(), token: String.t(), req: Req.Request.t()}

  @doc """
  Build a client. Reads `AOD_BASE_URL` and `AOD_TOKEN` from the environment
  if the corresponding option isn't passed.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_url =
      opts[:base_url] || System.get_env("AOD_BASE_URL") || "http://localhost:4000"

    token = opts[:token] || System.get_env("AOD_TOKEN") ||
              raise ArgumentError, "AOD_TOKEN not set (option or env)"

    base = String.trim_trailing(base_url, "/")

    req =
      Req.new(
        base_url: base <> "/api",
        auth: {:bearer, token},
        retry: false
      )

    %__MODULE__{base_url: base, token: token, req: req}
  end
end
