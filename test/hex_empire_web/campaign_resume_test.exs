defmodule HexEmpireWeb.CampaignResumeTest do
  use HexEmpireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HexEmpire.GameStore

  test "a campaign resumes on a different browser via its /c/ link", %{conn: conn} do
    GameStore.delete("resume-src")

    # Browser A plays a campaign
    conn_a = Plug.Test.init_test_session(conn, %{"campaign_id" => "resume-src"})
    {:ok, view_a, _} = live(conn_a, "/")
    g1 = :sys.get_state(view_a.pid).socket.assigns.game
    render_click(view_a, "end_turn", %{})

    # the sidebar shows the campaign's resume link
    assert render(view_a) =~ "/c/resume-src"

    # Browser B (fresh session) follows the link: session rebinds + redirect
    conn_b = Plug.Test.init_test_session(build_conn(), %{})
    conn_b = get(conn_b, "/c/resume-src")
    assert redirected_to(conn_b) == "/"
    assert Plug.Conn.get_session(conn_b, "campaign_id") == "resume-src"

    # ...and mounting the game on that session resumes the same campaign
    {:ok, view_b, _} =
      build_conn()
      |> Plug.Test.init_test_session(%{"campaign_id" => "resume-src"})
      |> live("/")

    g2 = :sys.get_state(view_b.pid).socket.assigns.game
    assert g2.seed == g1.seed
    assert g2.turns >= g1.turns
  end

  test "an unknown campaign token redirects home without rebinding", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{"campaign_id" => "my-own"})
    conn = get(conn, "/c/does-not-exist")
    assert redirected_to(conn) == "/"
    assert Plug.Conn.get_session(conn, "campaign_id") == "my-own"
  end

  test "fresh visitors get campaign_id defaulted to player_id", %{conn: conn} do
    conn = get(conn, "/")
    assert Plug.Conn.get_session(conn, "campaign_id") != nil
    assert Plug.Conn.get_session(conn, "campaign_id") == Plug.Conn.get_session(conn, "player_id")
  end
end
