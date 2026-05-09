defmodule AgentOnDemandWeb.Live.UpdateBannerTest do
  use AgentOnDemandWeb.ConnCase
  use Mimic

  import Phoenix.LiveViewTest

  alias AgentOnDemand.UpdateChecker

  @no_update_status %{
    current_version: "0.2.17",
    latest_version: nil,
    has_update: false,
    last_checked_at: nil,
    checking: false
  }

  setup do
    stub(UpdateChecker, :get_status, fn -> @no_update_status end)
    :ok
  end

  test "banner is hidden when no update is available", %{conn: conn} do
    {:ok, _view, html} = conn |> login() |> live(~p"/")
    refute html =~ "is available"
    refute html =~ "Upgrade"
  end

  test "banner shows version when update is available", %{conn: conn} do
    stub(UpdateChecker, :get_status, fn ->
      %{
        current_version: "0.2.17",
        latest_version: "0.2.18",
        has_update: true,
        last_checked_at: DateTime.utc_now(),
        checking: false
      }
    end)

    {:ok, _view, html} = conn |> login() |> live(~p"/")
    assert html =~ "0.2.18"
    assert html =~ "is available"
    assert html =~ "Upgrade"
  end

  test "check_for_updates event calls UpdateChecker.check_now", %{conn: conn} do
    expect(UpdateChecker, :check_now, fn -> :ok end)

    {:ok, view, _html} = conn |> login() |> live(~p"/")
    render_click(view, "check_for_updates")

    verify!(UpdateChecker)
  end

  test "sidebar always shows check for updates button", %{conn: conn} do
    {:ok, _view, html} = conn |> login() |> live(~p"/")
    assert html =~ "Check for updates"
  end
end
