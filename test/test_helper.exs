ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AgentOnDemand.Repo, :manual)

# Mimic copies modules so tests can stub/expect their functions without
# requiring us to wrap sprites-ex in an adapter behaviour. The list below
# is the full surface area of the SDK that AoD calls into.
Mimic.copy(Sprites)
Mimic.copy(Sprites.Filesystem)
Mimic.copy(AgentOnDemand.SpritesClient)
Mimic.copy(DynamicSupervisor)
