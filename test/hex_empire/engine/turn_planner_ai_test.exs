defmodule HexEmpire.Engine.TurnPlannerAiTest do
  use ExUnit.Case, async: true

  alias HexEmpire.Engine
  alias HexEmpire.Engine.{Ai, Query, Tournament, TurnPlannerAi}

  test "plans only legal moves and serves them action by action" do
    game = Engine.new_game(seed: 7, human: -1, spectating: true)
    party = game.turn_party

    plan = TurnPlannerAi.plan_turn(game, party)
    assert length(plan) <= 5

    # every planned move is legal when its turn comes (replay the plan)
    Enum.reduce(plan, game, fn {from, to}, g ->
      army = Query.army_at(g, from)
      assert army != nil and army.party == party and not army.moved
      assert to in Query.moves(g, from)
      {g, _} = HexEmpire.Engine.move(g, from, to)
      g
    end)
  end

  test "a full turn through the shared driver terminates and spends the budget" do
    game = Engine.new_game(seed: 11, human: -1, spectating: true)
    g = Ai.play_turn(game, TurnPlannerAi)
    assert g.actions == 0 or Query.movable_armies(g, g.turn_party) == []
  end

  test "a full challenger-vs-original game runs to completion deterministically" do
    a = Tournament.play_game(3, %{0 => TurnPlannerAi})
    b = Tournament.play_game(3, %{0 => TurnPlannerAi})
    assert a == b
    assert a.winner != nil
  end

  # Strength regression: excluded from normal runs (slow). Run with:
  #   mix test --only tournament
  @tag :tournament
  @tag timeout: 3_600_000
  test "beats the original AI decisively over the standard seed set" do
    results = Tournament.run(1..50, TurnPlannerAi)
    o = results.overall
    {low, _high} = Tournament.wilson(o.wins, o.games)

    # baseline null is 25%; require the CI floor to clear 35%
    assert low > 0.35,
           "challenger win rate #{o.wins}/#{o.games} (CI low #{low}) regressed below the 35% floor"
  end
end
