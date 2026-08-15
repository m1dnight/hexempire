defmodule HexEmpire.PushTest do
  use ExUnit.Case, async: false

  alias HexEmpire.Matches

  @sub %{"endpoint" => "https://push.example/sub1", "keys" => %{"p256dh" => "pk", "auth" => "a"}}

  setup do
    Application.put_env(:hex_empire, :push_test_pid, self())
    on_exit(fn -> Application.delete_env(:hex_empire, :push_test_pid) end)
    :ok
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

  test "subscription is stored on the seat and persists" do
    id = Matches.create()
    {:ok, t0} = Matches.claim_seat(id, 0, "p0")

    assert :ok = Matches.set_push_sub(id, t0, @sub)
    assert Matches.get(id).seats[0].push_sub == @sub

    # bogus token refused
    assert :error = Matches.set_push_sub(id, "nope", @sub)

    # survives a server restart (loaded back from disk)
    [{pid, _}] = Registry.lookup(HexEmpire.MatchRegistry, id)
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert Matches.get(id).seats[0].push_sub == @sub
  end

  test "a subscribed human seat is pushed when its turn arrives" do
    id = Matches.create()
    {:ok, t0} = Matches.claim_seat(id, 0, "p0")
    {:ok, t2} = Matches.claim_seat(id, 2, "p2")
    :ok = Matches.start_match(id, t0)

    # seat 2 subscribes; seat 0 (current turn) does not
    :ok = Matches.set_push_sub(id, t2, @sub)

    # ending seat 0's turn lets the AI seats play through to seat 2
    :ok = Matches.end_turn(id, t0)

    assert_receive {:push_sent, @sub, payload}, 5_000
    assert payload["title"] =~ "your move"
    assert payload["body"] =~ "Bluegaria"
    assert payload["url"] == "/m/#{id}"

    # no duplicate push while it stays seat 2's turn
    refute_receive {:push_sent, _, _}, 300
  end

  test "no push for AI seats or unsubscribed seats" do
    id = Matches.create()
    {:ok, t0} = Matches.claim_seat(id, 0, "p0")
    :ok = Matches.start_match(id, t0)

    # seat 0 never subscribed; all other seats are AI
    :ok = Matches.end_turn(id, t0)

    await(fn ->
      m = Matches.get(id)
      if m.game.turn_party == 0 or m.game.winner != nil, do: true
    end)

    refute_receive {:push_sent, _, _}, 300
  end
end
