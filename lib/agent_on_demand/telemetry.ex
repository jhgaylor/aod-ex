defmodule AgentOnDemand.Telemetry do
  @moduledoc """
  Custom telemetry events emitted by AoD's hot path. Two flavours:

  * `[:agent_on_demand, :<thing>, :<verb>, :start | :stop | :exception]` —
    `:telemetry.span/3`-style events, suitable for `OpentelemetryTelemetry`
    auto-instrumentation. Wrap any work whose duration matters.
  * Plain `:telemetry.execute/3` events for one-shot signals (a sandbox
    transitioned to ready, a turn started running) where there is no
    natural duration.

  ## Why not OpenTelemetry directly?

  OTel's BEAM libs add real setup ceremony and are easy to misconfigure
  in dev. Emitting plain `:telemetry` events is portable: an operator can
  attach `OpentelemetryTelemetry.attach/3` to map them onto OTel spans
  whenever they're ready, without us locking the app to the OTel runtime.

  ## Helpers

      AgentOnDemand.Telemetry.span([:provision, :install_packages], %{conv_id: id}, fn ->
        ... do the work ...
        {result, %{packages: 5}}
      end)

  Returns whatever the closure returns. Records `:start` + `:stop` (or
  `:exception`) events tagged under `[:agent_on_demand | name]`.

      AgentOnDemand.Telemetry.event([:turn, :queued], %{conv_id: id, turn_number: 2}, %{count: 1})
  """

  @prefix [:agent_on_demand]

  @doc """
  Wrap work in `:telemetry.span/3` with our `:agent_on_demand` prefix.

  The closure must return `{result, extra_metadata}` (typical
  `:telemetry.span/3` signature). To skip extra metadata, wrap with
  `{value, %{}}`.
  """
  def span(name, metadata, fun) when is_list(name) and is_map(metadata) and is_function(fun, 0) do
    :telemetry.span(@prefix ++ name, metadata, fun)
  end

  @doc "Emit a one-shot event under the `:agent_on_demand` prefix."
  def event(name, metadata \\ %{}, measurements \\ %{}) when is_list(name) do
    :telemetry.execute(@prefix ++ name, measurements, metadata)
  end

  @doc """
  Default telemetry → log handler. Renders every emitted event as a
  single JSON line on stdout. Cheap structured logging for free; an
  operator who wants real OTel attaches their own handler instead and
  detaches this one.
  """
  def attach_default_logger do
    events =
      for stage <- ~w(provision packages clone setup turn reattach)a,
          phase <- ~w(start stop exception)a,
          do: @prefix ++ [stage, phase]

    one_shots = [
      @prefix ++ [:turn, :queued],
      @prefix ++ [:turn, :interrupted],
      @prefix ++ [:sandbox, :failed]
    ]

    :telemetry.attach_many(
      "aod-default-logger",
      events ++ one_shots,
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(event_name, measurements, metadata, _config) do
    require Logger

    payload =
      %{
        event: Enum.join(event_name, "."),
        measurements: stringify(measurements),
        metadata: stringify(metadata)
      }
      |> Jason.encode!()

    Logger.info(payload)
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_value(v) when is_pid(v), do: inspect(v)
  defp stringify_value(v) when is_reference(v), do: inspect(v)
  defp stringify_value(v) when is_tuple(v), do: inspect(v)
  defp stringify_value(v) when is_function(v), do: inspect(v)
  defp stringify_value(v), do: v
end
