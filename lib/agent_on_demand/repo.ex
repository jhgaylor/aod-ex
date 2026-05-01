defmodule AgentOnDemand.Repo do
  use Ecto.Repo,
    otp_app: :agent_on_demand,
    adapter: Ecto.Adapters.SQLite3
end
