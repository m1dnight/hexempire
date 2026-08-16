defmodule HexEmpire.Engine.Tournament do
  @moduledoc """
  AI strength measurement: deterministic AI-vs-AI games and seat-rotated
  tournaments.

  A "game" is fully determined by its seed and the AI assignment, so results
  are reproducible. The standard experiment for a challenger: play every seed
  once per seat (4 games/seed) with the challenger in that seat and the
  reference AI in the other three, then compare each seat's win rate against
  the all-reference baseline for the same seeds (seat advantage is real, so
  comparisons are per-seat).
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.{Ai, OriginalAi, State}

  @max_steps 3000

  @typedoc "Result of one game."
  @type game_result :: %{
          winner: Engine.party() | nil,
          rounds: non_neg_integer(),
          steps: non_neg_integer()
        }

  @doc """
  Play one full AI-vs-AI game. `ai_by_party` maps party => AI module
  (default `OriginalAi` for unassigned seats). Step-capped; a nil winner
  means the cap was hit (scored as a draw).
  """
  @spec play_game(integer(), %{Engine.party() => module()}) :: game_result()
  def play_game(seed, ai_by_party \\ %{}) do
    game = Engine.new_game(seed: seed, human: -1, spectating: true)
    loop(game, ai_by_party, 0)
  end

  defp loop(game, ai_by_party, steps) do
    if game.winner != nil or steps >= @max_steps do
      %{winner: game.winner, rounds: game.turns, steps: steps}
    else
      module = Map.get(ai_by_party, game.turn_party, OriginalAi)
      game = Ai.play_turn(game, module)

      game =
        if game.winner == nil or game.screen == :game,
          do: State.finish_turn(game),
          else: game

      loop(game, ai_by_party, steps + 1)
    end
  end

  @doc """
  Seat-rotated tournament: for every seed and every seat, one game with
  `challenger` in that seat and `reference` elsewhere. `challenger == reference`
  gives the baseline seat-advantage table. Games run in parallel.

  Returns `%{seat => %{wins, games, rate, avg_rounds}}` plus `:overall`.
  """
  @spec run(Range.t() | [integer()], module(), module()) :: map()
  def run(seeds, challenger, reference \\ OriginalAi) do
    jobs = for seed <- seeds, seat <- 0..3, do: {seed, seat}

    results =
      jobs
      |> Task.async_stream(
        fn {seed, seat} ->
          result = play_game(seed, %{seat => challenger_for(challenger, reference, seat)})
          {seat, result}
        end,
        max_concurrency: System.schedulers_online(),
        timeout: 600_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)

    per_seat =
      Map.new(0..3, fn seat ->
        seat_results = for {s, r} <- results, s == seat, do: r
        wins = Enum.count(seat_results, &(&1.winner == seat))
        games = length(seat_results)

        {seat,
         %{
           wins: wins,
           games: games,
           rate: if(games > 0, do: wins / games, else: 0.0),
           avg_rounds: avg(Enum.map(seat_results, & &1.rounds)),
           draws: Enum.count(seat_results, &(&1.winner == nil))
         }}
      end)

    total_wins = Enum.sum(for {seat, r} <- results, r.winner == seat, do: 1)
    total_games = length(results)

    Map.put(per_seat, :overall, %{
      wins: total_wins,
      games: total_games,
      rate: if(total_games > 0, do: total_wins / total_games, else: 0.0)
    })
  end

  # challenger==reference means the "challenger seat" is just another reference
  # seat — the map entry keeps the game identical to an unassigned one.
  defp challenger_for(challenger, _reference, _seat), do: challenger

  defp avg([]), do: 0.0
  defp avg(list), do: Float.round(Enum.sum(list) / length(list), 1)

  @doc "95% Wilson score interval for `wins` out of `games` — {low, high}."
  @spec wilson(non_neg_integer(), pos_integer()) :: {float(), float()}
  def wilson(wins, games) do
    z = 1.96
    p = wins / games
    denom = 1 + z * z / games
    center = (p + z * z / (2 * games)) / denom
    margin = z * :math.sqrt(p * (1 - p) / games + z * z / (4 * games * games)) / denom
    {Float.round(center - margin, 3), Float.round(center + margin, 3)}
  end
end
