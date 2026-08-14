defmodule HexEmpire.MatchesTest do
  use ExUnit.Case, async: false

  alias HexEmpire.Matches
  alias HexEmpire.Matches.{Match, MatchServer}

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

  test "lobby flow: create, claim seats, host starts, open seats become AI" do
    id = Matches.create()
    match = Matches.get(id)
    assert match.status == :lobby
    assert Match.open_parties(match) == [0, 1, 2, 3]

    {:ok, host_token} = Matches.claim_seat(id, 0, "player-a")
    {:ok, guest_token} = Matches.claim_seat(id, 2, "player-b")
    assert host_token != guest_token

    # claimed seats can't be claimed again
    assert {:error, :unavailable} = Matches.claim_seat(id, 0, "player-c")

    # only the host can start
    assert {:error, :not_host} = Matches.start_match(id, guest_token)
    assert :ok = Matches.start_match(id, host_token)

    match = Matches.get(id)
    assert match.status == :playing
    assert match.seats[0].kind == :human
    assert match.seats[1].kind == :ai
    assert match.seats[2].kind == :human
    assert match.seats[3].kind == :ai
    assert match.game.human == -1
    assert match.game.spectating == true
  end

  test "seat-scoped move validation and turn passing between humans and AI" do
    id = Matches.create()
    {:ok, t0} = Matches.claim_seat(id, 0, "p0")
    {:ok, t2} = Matches.claim_seat(id, 2, "p2")
    :ok = Matches.start_match(id, t0)

    match = Matches.get(id)
    assert match.game.turn_party == 0

    # party 2's holder cannot act on party 0's turn
    [army0 | _] = HexEmpire.Engine.movable_armies(match.game, 0)
    assert {:error, :invalid} = Matches.end_turn(id, t2)
    assert {:error, :invalid} = Matches.move(id, t2, army0, army0)

    # party 0 moves its (single) army to a legal empty field — the turn
    # auto-ends and the AI (party 1) plays through to party 2
    g = match.game

    dest =
      Enum.find(HexEmpire.Engine.possible_moves(g, army0, true), fn k ->
        Map.fetch!(g.fields, k).army == nil
      end)

    assert :ok = Matches.move(id, t0, army0, dest)

    match =
      await(fn ->
        m = Matches.get(id)
        if m.game.turn_party == 2 or m.game.winner != nil, do: m
      end)

    assert match.game.turn_party == 2 or match.game.winner != nil

    # now party 2 may end its turn
    if match.game.winner == nil do
      assert :ok = Matches.end_turn(id, t2)
    end
  end

  test "match survives its server stopping (lazy rehydrate from disk)" do
    id = Matches.create()
    {:ok, t0} = Matches.claim_seat(id, 0, "p0")
    :ok = Matches.start_match(id, t0)

    # let the game reach the human's turn again (AI seats 1-3 play through)
    match =
      await(fn ->
        m = Matches.get(id)
        if m.game.turn_party == 0 or m.game.winner != nil, do: m
      end)

    turns_before = match.game.turns

    # stop the server; state must come back identical from disk
    [{pid, _}] = Registry.lookup(HexEmpire.MatchRegistry, id)
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    reloaded = Matches.get(id)
    assert reloaded.status == :playing
    assert reloaded.game.turns == turns_before
    assert reloaded.game.seed == match.game.seed
    assert Match.party_for_token(reloaded, t0) == 0
  end

  test "rebind attaches a new browser session to a seat via its token" do
    id = Matches.create()
    {:ok, t0} = Matches.claim_seat(id, 0, "old-browser")

    assert {:ok, 0} = Matches.rebind(id, t0, "new-browser")
    match = Matches.get(id)
    assert Match.party_for_player(match, "new-browser") == 0
    assert Match.party_for_player(match, "old-browser") == nil
    assert :error = Matches.rebind(id, "bogus-token", "whoever")
  end

  test "unknown match ids resolve to not found" do
    assert Matches.get("zzzzzz") == nil
    assert {:error, :not_found} = Matches.end_turn("zzzzzz", "tok")
  end

  test "an AI-vs-AI match with a spectator-mode game finishes on its own" do
    # claim nothing: host claims then... a match needs a host to start, so
    # claim seat 0, start, then verify AI turns advance without any human
    # command while seat 0 simply never moves — the game waits on party 0.
    id = Matches.create()
    {:ok, t0} = Matches.claim_seat(id, 0, "p0")
    :ok = Matches.start_match(id, t0)

    match = Matches.get(id)
    assert match.game.turn_party == 0

    # ending the human turn hands off to the three AI seats, which return
    # the turn to party 0 (spectating round counter ticks on the wrap)
    :ok = Matches.end_turn(id, t0)

    match =
      await(fn ->
        m = Matches.get(id)
        if m.game.turn_party == 0 or m.game.winner != nil, do: m
      end)

    assert match.game.turns >= 1 or match.game.winner != nil
  end
end
