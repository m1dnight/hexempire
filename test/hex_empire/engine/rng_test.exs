defmodule HexEmpire.Engine.RngTest do
  use ExUnit.Case, async: true

  alias HexEmpire.Engine.Rng

  @vectors Path.expand("../../golden/rng_vectors.jsonl", __DIR__)

  test "matches golden vectors from the original JS engine" do
    vectors =
      for line <- File.stream!(@vectors),
          line = String.trim(line),
          line != "",
          do: Jason.decode!(line)

    assert vectors != [], "rng_vectors.jsonl is empty — nothing was asserted"

    for v <- vectors do
      rng = Rng.set_seed(v["seed"])

      case v do
        %{"draws" => draws} ->
          final =
            Enum.reduce(draws, rng, fn [n, expected], s ->
              {value, s2} = Rng.next_int(s, n)

              assert value == expected,
                     "seed #{v["seed"]}: nextInt(#{n}) => #{value}, want #{expected}"

              s2
            end)

          assert final == v["final"], "seed #{v["seed"]}: final seed #{final}, want #{v["final"]}"

        %{"shuffle" => expected} ->
          {shuffled, final} = Rng.shuffle(rng, Enum.to_list(0..9))
          assert shuffled == expected, "seed #{v["seed"]}: shuffle mismatch"
          assert final == v["final"], "seed #{v["seed"]}: final seed #{final}, want #{v["final"]}"
      end
    end
  end
end
