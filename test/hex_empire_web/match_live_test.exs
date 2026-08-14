defmodule HexEmpireWeb.MatchLiveTest do
  use HexEmpireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HexEmpire.Matches

  defp session_conn(conn, player_id) do
    Plug.Test.init_test_session(conn, %{"player_id" => player_id})
  end

  defp await(fun, deadline_ms \\ 5_000) do
    result = fun.()

    cond do
      result ->
        result

      deadline_ms <= 0 ->
        flunk("condition never became truthy")

      true ->
        Process.sleep(20)
        await(fun, deadline_ms - 20)
    end
  end

  test "unknown match renders not-found", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/m/zzzzzz")
    assert html =~ "Match not found"
  end

  test "creating a match from the solo page navigates to its lobby", %{conn: conn} do
    {:ok, view, _html} = live(session_conn(conn, "creator"), "/")

    assert {:error, {:live_redirect, %{to: "/m/" <> id}}} =
             render_click(view, "create_match", %{})

    {:ok, _view, html} = live(session_conn(conn, "creator"), "/m/#{id}")
    assert html =~ "Match #{id}"
    assert html =~ "Claim"
  end

  test "two browsers: claim, start, play a move, both see updates", %{conn: conn} do
    id = Matches.create()

    # host (browser A) claims Redosia
    {:ok, host, _} = live(session_conn(conn, "browser-a"), "/m/#{id}")
    render_click(host, "claim", %{"party" => "0"})
    html = render(host)
    assert html =~ "Your personal rejoin link"
    # share + rejoin links render as full copy-pasteable URLs
    assert html =~ ~r{http://www\.example\.com/m/#{id}\?seat=}
    assert html =~ "http://www.example.com/m/#{id}"

    # guest (browser B) claims Bluegaria
    {:ok, guest, _} = live(session_conn(conn, "browser-b"), "/m/#{id}")
    render_click(guest, "claim", %{"party" => "2"})

    # guest cannot start; host can
    render_click(guest, "start", %{})
    assert Matches.get(id).status == :lobby
    render_click(host, "start", %{})
    assert Matches.get(id).status == :playing

    # both now render the board (PubSub pushed the transition)
    await(fn -> render(host) =~ "End Turn" || nil end)
    await(fn -> render(guest) =~ "End Turn" || nil end)

    # host (party 0) moves their single army to an empty field via clicks
    g = Matches.get(id).game
    assert g.turn_party == 0
    [army | _] = HexEmpire.Engine.movable_armies(g, 0)
    host |> element(~s{polygon[phx-value-k="#{army}"]}) |> render_click()

    dest =
      :sys.get_state(host.pid).socket.assigns.valid_moves
      |> Enum.find(fn k -> Map.fetch!(g.fields, k).army == nil end)

    host |> element(~s{polygon[phx-value-k="#{dest}"]}) |> render_click()

    # single army -> auto end turn -> AI seats play -> guest's turn (party 2)
    match =
      await(fn ->
        m = Matches.get(id)
        if m.game.turn_party == 2 or m.game.winner != nil, do: m
      end)

    if match.game.winner == nil do
      # the guest's view got the update and can end its turn
      await(fn ->
        assigns = :sys.get_state(guest.pid).socket.assigns
        if assigns.match.game.turn_party == 2, do: true
      end)

      render_click(guest, "end_turn", %{})

      await(fn ->
        m = Matches.get(id)
        if m.game.turn_party != 2 or m.game.winner != nil, do: true
      end)
    end
  end

  test "personal seat link rebinds a different browser to the seat", %{conn: conn} do
    id = Matches.create()
    {:ok, token} = Matches.claim_seat(id, 1, "original-browser")

    # a brand-new browser opens the personal link and is bound to party 1
    {:ok, view, html} = live(session_conn(conn, "other-device"), "/m/#{id}?seat=#{token}")
    assert html =~ "(you)"
    assert :sys.get_state(view.pid).socket.assigns.party == 1

    # and afterwards even the PLAIN link resumes the seat on that browser
    {:ok, view2, _} = live(session_conn(conn, "other-device"), "/m/#{id}")
    assert :sys.get_state(view2.pid).socket.assigns.party == 1
  end

  test "spectators see the board but hold no controls", %{conn: conn} do
    id = Matches.create()
    {:ok, t0} = Matches.claim_seat(id, 0, "p0")
    :ok = Matches.start_match(id, t0)

    {:ok, view, html} = live(session_conn(conn, "random-visitor"), "/m/#{id}")
    assert html =~ "You are spectating."
    assert :sys.get_state(view.pid).socket.assigns.party == nil
    refute html =~ "End Turn"
  end
end
