defmodule AgentOnDemandWeb.HealthController do
  use AgentOnDemandWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias AgentOnDemandWeb.Schemas

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Health"])
  security([])

  operation(:show,
    summary: "Liveness probe",
    description: "Public, unauthenticated. Returns `{\"status\": \"ok\"}` if the app is up.",
    responses: [
      ok: {"Health response", "application/json", Schemas.HealthResponse}
    ]
  )

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
