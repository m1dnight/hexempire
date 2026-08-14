defmodule HexEmpireWeb.GameLiveTest do
  use HexEmpireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HexEmpire.Engine.State

  # Poll the LiveView's game state until control returns to the human (or the
  # game ends) instead of sleeping a fixed amount — the AI runs on :ai_step
  # timers whose cadence is config-driven (1ms in test).
  defp await_human_turn(view, deadline_ms \\ 10_000) do
    g = :sys.get_state(view.pid).socket.assigns.game

    cond do
      g.turn_party == g.human or g.winner != nil ->
        g

      deadline_ms <= 0 ->
        flunk("AI never handed control back to the human")

      true ->
        Process.sleep(50)
        await_human_turn(view, deadline_ms - 50)
    end
  end

  test "mounts and renders the original 20x11 board", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "HEX EMPIRE"
    assert html =~ "End Turn"
    # 220 board polygons
    assert length(String.split(html, "phx-click=\"hex\"")) - 1 == 220
    assert html =~ "Redosia"
    assert html =~ "Violetnam"
  end

  test "selecting an own army highlights moves; clicking one moves it", %{conn: conn} do
    # The human starts with a single army, so its first move would auto-finish
    # the turn and let the (fast, 1ms-cadence) AI mutate the board before we
    # can assert. Pre-seed the campaign with a second human army so the move
    # leaves an action budget and the post-state is deterministic.
    g = State.create_game(seed: 42, human: 0, difficulty: 5)

    extra =
      Enum.find(g.field_order, fn k ->
        f = Map.fetch!(g.fields, k)
        f.type == :land and f.army == nil and f.estate == nil
      end)

    {g, _} = HexEmpire.Engine.Army.create(g, extra, 0, 10, 5)
    g = State.begin_turn(g, 0)

    HexEmpire.GameStore.delete("test-move")
    HexEmpire.GameStore.save("test-move", %{game: g, difficulty: 5})
    conn = Plug.Test.init_test_session(conn, %{"player_id" => "test-move"})

    {:ok, view, _html} = live(conn, "/")

    g = :sys.get_state(view.pid).socket.assigns.game
    assert g.human == 0
    assert g.actions >= 2
    # find an unmoved human army
    [key | _] = State.movable_armies(g, 0)

    html = view |> element(~s{polygon[phx-value-k="#{key}"]}) |> render_click()
    assert html =~ "choose a destination"

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.selected == key
    assert assigns.valid_moves != []

    # pick an EMPTY destination so the outcome is deterministic (no combat);
    # on turn 1 the starting armies always have at least one empty neighbour
    dest = Enum.find(assigns.valid_moves, fn k -> Map.fetch!(g.fields, k).army == nil end)
    assert dest != nil, "no empty destination among valid moves"

    view |> element(~s{polygon[phx-value-k="#{dest}"]}) |> render_click()

    assigns2 = :sys.get_state(view.pid).socket.assigns
    g2 = assigns2.game

    # the army arrived, the origin is cleared, and the selection was dropped
    a = Map.fetch!(g2.fields, dest).army
    assert a != nil and a.party == 0 and a.moved
    assert Map.fetch!(g2.fields, key).army == nil
    assert assigns2.selected == nil
  end

  test "ending the turn hands control to the AI factions", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_click(view, "end_turn", %{})
    g = :sys.get_state(view.pid).socket.assigns.game
    assert g.turn_party != 0
  end

  test "AI turns eventually come back around to the human", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_click(view, "end_turn", %{})

    g = await_human_turn(view)
    assert g.turn_party == 0 or g.winner != nil
    # turns increments exactly when control returns to the human (turn 1 is
    # the initial human turn), so a completed round means turns == 2
    assert g.turns == 2 or g.winner != nil
  end

  test "new game with a different faction", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_submit(view, "new_game", %{"faction" => "2", "difficulty" => "10"})
    g = :sys.get_state(view.pid).socket.assigns.game
    assert g.human == 2
    assert g.difficulty == 10
  end

  test "game survives a refresh (same session resumes the same campaign)", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{"player_id" => "test-persist-1"})
    HexEmpire.GameStore.delete("test-persist-1")

    {:ok, view, _html} = live(conn, "/")
    g1 = :sys.get_state(view.pid).socket.assigns.game

    # play: end the turn so state visibly changes, let AI finish
    render_click(view, "end_turn", %{})
    g2 = await_human_turn(view)
    assert g2.turns >= g1.turns

    # "refresh": a fresh LiveView on the same session
    {:ok, view2, _html} = live(conn, "/")
    g3 = :sys.get_state(view2.pid).socket.assigns.game
    assert g3.seed == g1.seed
    assert g3.turns >= g2.turns
  end

  test "different sessions get different campaigns", %{conn: conn} do
    conn_a = Plug.Test.init_test_session(conn, %{"player_id" => "test-persist-a"})
    conn_b = Plug.Test.init_test_session(conn, %{"player_id" => "test-persist-b"})
    HexEmpire.GameStore.delete("test-persist-a")
    HexEmpire.GameStore.delete("test-persist-b")

    {:ok, va, _} = live(conn_a, "/")
    {:ok, vb, _} = live(conn_b, "/")
    ga = :sys.get_state(va.pid).socket.assigns.game
    gb = :sys.get_state(vb.pid).socket.assigns.game

    # each session persisted its own independent campaign under its own key
    # (seeds come from :rand.uniform(999_999), so asserting seed inequality
    # would flake ~1 in 10^6 — store isolation is the real contract)
    stored_a = HexEmpire.GameStore.fetch("test-persist-a")
    stored_b = HexEmpire.GameStore.fetch("test-persist-b")
    assert stored_a != nil and stored_b != nil
    assert stored_a.game.seed == ga.seed
    assert stored_b.game.seed == gb.seed
  end
end
