defmodule Mix.Tasks.Ai.Tournament do
  @shortdoc "Measure an AI module's strength against the original AI"

  @moduledoc """
  Seat-rotated AI tournament.

      mix ai.tournament                          # baseline: original vs itself
      mix ai.tournament --games 100              # seeds 1..100 (x4 seats each)
      mix ai.tournament --challenger Elixir.HexEmpire.Engine.ChallengerAi

  Per seat: the challenger plays that seat, the reference plays the rest.
  Compare each seat's win rate against the baseline run (seat advantage is
  significant in Hex Empire, so overall averages alone mislead).
  """

  use Mix.Task

  alias HexEmpire.Engine.{OriginalAi, Tournament}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [games: :integer, challenger: :string, reference: :string]
      )

    Mix.Task.run("app.start")

    games = opts[:games] || 50
    challenger = module!(opts[:challenger]) || OriginalAi
    reference = module!(opts[:reference]) || OriginalAi

    label = if challenger == reference, do: "baseline (self-play)", else: inspect(challenger)
    IO.puts("Tournament: #{label} vs #{inspect(reference)} — seeds 1..#{games}, 4 seats each\n")

    {micro, results} = :timer.tc(fn -> Tournament.run(1..games, challenger, reference) end)

    IO.puts("seat  wins/games   rate    95% CI          avg rounds  draws")

    for seat <- 0..3 do
      r = results[seat]
      {lo, hi} = Tournament.wilson(r.wins, max(r.games, 1))

      IO.puts(
        "  #{seat}   #{String.pad_leading("#{r.wins}", 4)}/#{String.pad_trailing("#{r.games}", 6)}" <>
          " #{pct(r.rate)}  [#{pct(lo)} – #{pct(hi)}]   #{r.avg_rounds}       #{r.draws}"
      )
    end

    o = results.overall
    {lo, hi} = Tournament.wilson(o.wins, max(o.games, 1))
    IO.puts("\noverall: #{o.wins}/#{o.games} = #{pct(o.rate)}  [#{pct(lo)} – #{pct(hi)}]")
    IO.puts("(#{Float.round(micro / 1_000_000, 1)}s)")
  end

  defp pct(x), do: String.pad_leading("#{Float.round(x * 100, 1)}%", 6)

  defp module!(nil), do: nil
  defp module!(name), do: String.to_existing_atom(name)
end
