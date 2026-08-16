defmodule HexEmpire.Campaigns do
  @moduledoc """
  Campaign lifecycle and persistence policy for player sessions.

  A campaign is a plain map `%{player_id, game, difficulty}` tying a player's
  saved slot to a running `HexEmpire.Engine` game. Every mutator persists the
  campaign through `HexEmpire.GameStore` (a no-op when `player_id` is nil),
  so callers only assign the returned state.

  All game logic goes through the `HexEmpire.Engine` facade — the engine is
  frozen (see its moduledoc) and this module owns only the session-level
  decisions: when a human move auto-ends the turn, and when an AI step
  finishes (or skips) the AI's turn.
  """

  alias HexEmpire.{Engine, GameStore}
  alias HexEmpire.Engine.{OriginalAi, TurnPlannerAi}

  # Difficulty 15 is the "Brutal" sentinel: enemies run the TurnPlannerAi
  # challenger (beam search) instead of the classic greedy AI. 0/5/10 map to
  # the original's easy/normal/hard biases.
  @brutal 15

  @doc "The AI module playing the campaign's enemy parties."
  @spec ai_module(non_neg_integer()) :: module()
  def ai_module(difficulty) when difficulty >= @brutal, do: TurnPlannerAi
  def ai_module(_difficulty), do: OriginalAi

  @typedoc "A player's campaign: the saved game plus its difficulty setting."
  @type t :: %{
          player_id: String.t() | nil,
          game: Engine.game(),
          difficulty: non_neg_integer()
        }

  @doc """
  Resume the player's saved campaign, or nil when there is none (or no
  player id).
  """
  @spec resume(String.t() | nil) :: t() | nil
  def resume(player_id) do
    case GameStore.fetch(player_id) do
      %{game: game, difficulty: difficulty} ->
        %{player_id: player_id, game: game, difficulty: difficulty}

      _ ->
        nil
    end
  end

  @doc """
  Start (and persist) a fresh campaign for the player: a new randomly seeded
  game with the human playing `faction`.
  """
  @spec new_campaign(String.t() | nil, Engine.party(), non_neg_integer()) :: t()
  def new_campaign(player_id, faction, difficulty) do
    # the engine's difficulty stays in the original's 0..10 range (its scoring
    # biases); Brutal (15) is a campaign-level setting selecting the AI module
    game =
      Engine.new_game(
        seed: :rand.uniform(999_999),
        human: faction,
        difficulty: min(difficulty, 10)
      )

    save(%{player_id: player_id, game: game, difficulty: difficulty})
  end

  @doc """
  Perform a human move from `from` to `to` and auto-end the turn when the
  action budget runs out. Returns `{campaign, moved?}`; an invalid move (not
  the human's turn, no budget, no own unmoved army on `from`, or `to` not in
  `Engine.possible_moves/3`) leaves the campaign untouched with `moved?` false.
  """
  @spec human_move(t(), Engine.field_key(), Engine.field_key()) :: {t(), boolean()}
  def human_move(%{game: g} = campaign, from, to) do
    origin = Map.get(g.fields, from)

    valid? =
      g.winner == nil and g.turn_party == g.human and g.actions > 0 and
        origin != nil and origin.army != nil and origin.army.party == g.human and
        not origin.army.moved and to in Engine.possible_moves(g, from, true)

    if valid? do
      {g, _result} = Engine.move(g, from, to)
      g = if g.actions <= 0 and g.winner == nil, do: Engine.end_turn(g), else: g
      {save(%{campaign | game: g}), true}
    else
      {campaign, false}
    end
  end

  @doc "End the current turn and persist."
  @spec end_turn(t()) :: t()
  def end_turn(campaign) do
    save(%{campaign | game: Engine.end_turn(campaign.game)})
  end

  @doc """
  Advance an AI turn by one step: perform one AI action when the party still
  has budget and movable armies, then finish the turn when the action yielded
  nothing, exhausted the budget, or left no movable armies. A game already
  decided mid-step (winner set, screen no longer `:game`) skips the finish.
  """
  @spec ai_step(t()) :: t()
  def ai_step(%{game: g, difficulty: difficulty} = campaign) do
    {g, result} =
      if g.actions > 0 and Engine.movable_armies(g) != [] do
        Engine.ai_step(g, ai_module(difficulty))
      else
        {g, nil}
      end

    g =
      if result == nil or g.actions <= 0 or Engine.movable_armies(g) == [] do
        if g.winner == nil or g.screen == :game, do: Engine.end_turn(g), else: g
      else
        g
      end

    save(%{campaign | game: g})
  end

  @doc "Persist the campaign (no-op without a player id). Returns the campaign."
  @spec save(t()) :: t()
  def save(%{player_id: nil} = campaign), do: campaign

  def save(%{player_id: player_id} = campaign) do
    GameStore.save(player_id, %{game: campaign.game, difficulty: campaign.difficulty})
    campaign
  end

  @doc "Delete the player's saved campaign."
  @spec delete(String.t()) :: :ok
  defdelegate delete(player_id), to: GameStore
end
