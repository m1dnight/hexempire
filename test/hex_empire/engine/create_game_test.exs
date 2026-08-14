defmodule HexEmpire.Engine.CreateGameTest do
  use ExUnit.Case, async: true

  import HexEmpire.Golden, only: [init_line: 1, army_snapshot: 1]

  alias HexEmpire.Engine.State

  for seed <- [1, 7, 42, 123] do
    test "create_game matches original init state (seed #{seed})" do
      init = init_line(unquote(seed))
      game = State.create_game(seed: unquote(seed), human: -1)

      assert game.rng == init["rng"], "rng"
      assert game.morale == init["morale"], "faction morale"
      assert game.turn_party == init["turnParty"]
      assert game.actions == init["actions"]
      assert army_snapshot(game) == init["armies"]
    end
  end
end
