defmodule HexEmpire.CampaignHistoryTest do
  use ExUnit.Case, async: false

  alias HexEmpire.{Campaigns, GameStore}

  test "history records one sample per round and persists" do
    GameStore.delete("hist-1")
    c = Campaigns.new_campaign("hist-1", 0, 5)

    # a fresh campaign has its round-1 snapshot
    assert [%{t: t, counts: counts}] = c.history
    assert t == c.game.turns
    assert length(counts) == 4

    # ending turns advances rounds; each new round appends exactly one sample
    c = Enum.reduce(1..3, c, fn _, acc -> Campaigns.end_turn(acc) end)
    rounds = c.history |> Enum.map(& &1.t) |> Enum.uniq()
    assert rounds == Enum.sort(rounds, :desc), "history is newest-first"
    assert length(c.history) == length(rounds), "no duplicate samples within a round"

    # persisted and reloadable
    reloaded = Campaigns.resume("hist-1")
    assert reloaded.history == c.history
  end

  test "resume defaults history to [] for a pre-history save" do
    GameStore.save("hist-old", %{game: :placeholder_game, difficulty: 5})
    # fetch returns the raw map; resume must not crash on the missing key
    assert %{history: []} = Campaigns.resume("hist-old")
  after
    GameStore.delete("hist-old")
  end
end
