defmodule HexEmpire.Engine.ReplayTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The decisive differential test: replay entire AI-vs-AI games and require the
  Elixir engine to match the original JS engine's state after EVERY turn —
  RNG seed, faction morale, status, every army (id/field/count/morale/moved),
  every field's owner, and the winner.
  """

  import HexEmpire.Golden, only: [trace: 1, army_snapshot: 1, field_snapshot: 1]

  alias HexEmpire.Engine.{OriginalAi, State}

  # {trace file suffix, seed, human, difficulty}
  @scenarios [
    {"1", 1, -1, 5},
    {"7", 7, -1, 5},
    {"42", 42, -1, 5},
    {"123", 123, -1, 5},
    {"777", 777, -1, 5},
    {"31337", 31_337, -1, 5},
    {"h5", 5, 0, 5},
    {"h9", 9, 2, 10},
    {"h11", 11, 1, 0}
  ]

  for {suffix, seed, human, difficulty} <- @scenarios do
    @tag timeout: 600_000
    test "full-game replay matches the original engine (trace #{suffix})" do
      [_init | turns] = trace(unquote(suffix))
      assert turns != [], "trace #{unquote(suffix)}: no turn lines"

      game =
        State.create_game(
          seed: unquote(seed),
          human: unquote(human),
          difficulty: unquote(difficulty)
        )

      Enum.reduce(turns, game, fn expected, g ->
        step = expected["step"]

        g = OriginalAi.perform_fast_ai_turn(g)
        # matches the trace driver: skip finishTurn once a human game has ended
        g = if g.winner == nil or g.screen == :game, do: State.finish_turn(g), else: g

        assert g.rng == expected["rng"], "step #{step}: rng #{g.rng} want #{expected["rng"]}"
        assert g.turn_party == expected["turnParty"], "step #{step}: turnParty"
        assert g.actions == expected["actions"], "step #{step}: actions"
        assert g.morale == expected["morale"], "step #{step}: morale"
        assert g.status == expected["status"], "step #{step}: status"
        assert army_snapshot(g) == expected["armies"], "step #{step}: armies"
        assert field_snapshot(g) == expected["fields"], "step #{step}: fields"

        assert g.winner == expected["winner"],
               "step #{step}: winner #{inspect(g.winner)} want #{inspect(expected["winner"])}"

        g
      end)
    end
  end
end
