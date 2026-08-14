defmodule HexEmpire.Engine.GeneratorTest do
  use ExUnit.Case, async: true

  import HexEmpire.Golden, only: [init_line: 1]

  alias HexEmpire.Engine.{Generator, Rng}

  for seed <- [1, 7, 42, 123] do
    test "map generation matches the original engine bit-for-bit (seed #{seed})" do
      init = init_line(unquote(seed))

      rng = Rng.set_seed(unquote(seed))
      board = Generator.generate(rng)

      # capitals in party order
      assert board.capitals == init["capitals"]

      # every field: type, estate, party (guard against a truncated trace —
      # the `for` pattern below silently skips entries missing a key)
      assert length(init["map"]) == 220
      assert map_size(board.fields) == 220

      for %{"k" => k, "t" => t, "e" => e, "p" => p} <- init["map"] do
        f = Map.fetch!(board.fields, k)
        assert Atom.to_string(f.type) == t, "#{k}: type #{f.type} want #{t}"

        estate = if f.estate, do: Atom.to_string(f.estate), else: nil
        assert estate == e, "#{k}: estate #{inspect(estate)} want #{inspect(e)}"
        assert f.party == p, "#{k}: party #{f.party} want #{p}"
      end

      # the RNG seed after generation must match the original's snapshot
      assert board.rng == init["rng"]
    end
  end
end
