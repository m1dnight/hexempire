defmodule HexEmpire.Engine.Ai do
  @moduledoc """
  The AI player contract and the shared turn driver.

  An AI module implements `play_action/1`: make ONE move for the current turn
  party and return `{game, result}` (result nil when no move was possible —
  the driver then zeroes the budget, mirroring the original UI loop).

  `play_turn/2` drives a whole turn: repeat `play_action` while the party has
  budget and movable armies, re-evaluating after every move. This loop is
  shared by every AI so match/campaign behavior stays uniform; `OriginalAi`
  is the golden-verified reference implementation.
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.Query

  @callback play_action(Engine.game()) :: {Engine.game(), Engine.move_result() | nil}

  @doc "Play the current party's entire turn with `module`. Does not finish the turn."
  @spec play_turn(Engine.game(), module()) :: Engine.game()
  def play_turn(game, module) do
    party = game.turn_party

    if game.screen == :game and game.turn_party == party and game.actions > 0 and
         Query.movable_armies(game, party) != [] do
      {game, result} = module.play_action(game)

      game =
        if result == nil and game.actions > 0,
          do: %{game | actions: 0},
          else: game

      play_turn(game, module)
    else
      game
    end
  end
end
