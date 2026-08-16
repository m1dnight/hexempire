defmodule HexEmpire.BrutalDifficultyTest do
  use ExUnit.Case, async: false

  alias HexEmpire.{Campaigns, Matches}
  alias HexEmpire.Engine.{OriginalAi, TurnPlannerAi}
  alias HexEmpire.Matches.Match

  test "campaign difficulty maps to the AI module" do
    assert Campaigns.ai_module(0) == OriginalAi
    assert Campaigns.ai_module(5) == OriginalAi
    assert Campaigns.ai_module(10) == OriginalAi
    assert Campaigns.ai_module(15) == TurnPlannerAi
  end

  test "a brutal campaign's engine difficulty stays in the original's range" do
    campaign = Campaigns.new_campaign(nil, 0, 15)
    assert campaign.difficulty == 15
    assert campaign.game.difficulty == 10
  end

  test "a brutal solo campaign plays AI turns to completion" do
    campaign = Campaigns.new_campaign(nil, 0, 15)
    campaign = Campaigns.end_turn(campaign)

    # step the (brutal) AI parties until the round returns to the human
    campaign =
      Enum.reduce_while(1..50, campaign, fn _, c ->
        if c.game.turn_party == c.game.human or c.game.winner != nil,
          do: {:halt, c},
          else: {:cont, Campaigns.ai_step(c)}
      end)

    assert campaign.game.turn_party == campaign.game.human or campaign.game.winner != nil
  end

  test "host can toggle brutal computers in the lobby, not after start" do
    id = Matches.create()
    {:ok, host} = Matches.claim_seat(id, 0, "host")
    {:ok, guest} = Matches.claim_seat(id, 1, "guest")

    # only the host may toggle
    assert {:error, :invalid} = Matches.set_brutal(id, guest, true)
    assert :ok = Matches.set_brutal(id, host, true)

    match = Matches.get(id)
    assert Match.ai_module(match) == TurnPlannerAi

    :ok = Matches.start_match(id, host)
    assert {:error, :invalid} = Matches.set_brutal(id, host, false)
  end

  test "matches saved before the flag existed read as classic" do
    # a Match struct stripped of the new key, as an old save would decode
    old = Matches.get(Matches.create()) |> Map.delete(:brutal_ai)
    assert Match.ai_module(old) == OriginalAi
  end
end
