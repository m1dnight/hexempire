defmodule HexEmpire.Engine.CombatTest do
  use ExUnit.Case, async: true

  alias HexEmpire.Engine.{Army, Combat, Game}

  @vectors Path.expand("../../golden/combat_vectors.jsonl", __DIR__)

  # Minimal game: empty board (no armies), so add_for_all is a no-op — matching
  # how the JS vectors were generated (synthetic armies not in game.armies).
  defp bare_game(luck?, rng_seed) do
    struct!(Game,
      fields: %{},
      field_order: [],
      armies_by_party: [[], [], [], []],
      army_pos: %{},
      rules: %{battle_luck: luck?},
      rng: rng_seed,
      morale: [10, 10, 10, 10],
      total_count: [0, 0, 0, 0]
    )
  end

  test "matches all golden combat vectors from the original engine" do
    lines = File.stream!(@vectors) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    assert length(lines) > 700

    for line <- lines do
      v = Jason.decode!(line)
      [ac, am, dc, dm] = v["in"]
      game = bare_game(v["luck"] == 1, 777)

      attacker = %Army{id: 0, party: 0, count: ac, morale: am, moved: false}
      defender = %Army{id: 1, party: 1, count: dc, morale: dm, moved: false}

      {game, a2, d2, result} = Combat.resolve(game, attacker, defender)

      expected_winner = String.to_atom(v["winner"])

      assert result.winner == expected_winner,
             "#{inspect(v["in"])} luck=#{v["luck"]}: got #{result.winner}, want #{v["winner"]}"

      assert result.attack_power == v["ap"]
      assert result.defence_power == v["dp"]
      assert [a2.count, a2.morale] == v["a"], "attacker after: #{inspect(v)}"
      assert [d2.count, d2.morale] == v["d"], "defender after: #{inspect(v)}"
      assert game.rng == v["rng"], "rng after: #{inspect(v)}"
    end
  end
end
