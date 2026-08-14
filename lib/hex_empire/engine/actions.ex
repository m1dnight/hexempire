defmodule HexEmpire.Engine.Actions do
  @moduledoc """
  Port of original/actions.js — moveArmy and spendAction (cheat/alliance
  branches dead; smite is handOfGod-only and omitted).

  RNG accounting per battle (order matters, shared LCG):
    1 draw  nextInt(3)  — war/gun sound choice
    combat  (2 draws only when battleLuck is on)
    48 draws — battle scar: nextInt(2), nextInt(2), nextInt(360),
               then 15 x (nextInt(6), nextInt(50), nextInt(40))
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.{Army, Combat, Config, Rng, State, Territory}

  @doc """
  Move the army on `from_key` to `to_key` (already validated by possibleMoves).
  Returns `{game, result}` with result.winner in
  `:attacker | :defender | :merge`. The caller is responsible for spending
  the action afterwards (`spend_action/1` is not called here).
  """
  @spec move_army(Engine.game(), Engine.field_key(), Engine.field_key()) ::
          {Engine.game(), Engine.move_result()}
  def move_army(game, from_key, to_key) do
    origin = Map.fetch!(game.fields, from_key)
    army = origin.army
    target = Map.fetch!(game.fields, to_key)
    defender = target.army

    # origin.army = null; army.moved = true (army "in flight")
    game = Army.put_army(game, from_key, nil)
    army = %{army | moved: true}

    cond do
      defender != nil and defender.party != army.party ->
        attack(game, army, defender, to_key)

      defender != nil ->
        merge(game, army, defender, from_key, to_key)

      true ->
        game = Army.put_army(game, to_key, army)
        game = Territory.annex_land(game, army.party, to_key)
        game = State.update_derived(game)
        {game, %{winner: :attacker}}
    end
  end

  defp attack(game, army, defender, to_key) do
    # sound draw
    {_, rng} = Rng.next_int(game.rng, 3)
    game = %{game | rng: rng}

    {game, army, defender, result} = Combat.resolve(game, army, defender)

    # battle scar: 48 draws (values cosmetic, stream consumption is not)
    game = battle_scar(game)

    if result.winner == :defender do
      # defender holds (already on the target field with reduced strength)
      game = Army.put_army(game, to_key, defender)
      game = State.update_derived(game)
      game = State.log(game, battle_msg(game, army, defender, :defender))
      {game, result}
    else
      game = Army.put_army(game, to_key, army)
      game = Territory.annex_land(game, army.party, to_key)
      game = State.update_derived(game)
      game = State.log(game, battle_msg(game, army, defender, :attacker))
      {game, %{winner: :attacker}}
    end
  end

  defp merge(game, army, defender, from_key, to_key) do
    total = defender.count + army.count
    max_army = Config.max_army()

    game =
      if total <= max_army do
        {g, _} = Army.join(game, to_key, army.party, army.count, army.morale)
        g
      else
        left = total - max_army
        {g, _} = Army.join(game, to_key, army.party, max_army - defender.count, army.morale)
        {g, _} = Army.create(g, from_key, army.party, left, army.morale)
        g
      end

    # merged stack cannot move again this turn
    game =
      %{
        game
        | fields:
            Map.update!(game.fields, to_key, fn f -> %{f | army: %{f.army | moved: true}} end)
      }

    game = Territory.annex_land(game, army.party, to_key)
    game = State.update_derived(game)
    {game, %{winner: :merge}}
  end

  @doc "spendAction: count the move, decrement, re-cap to remaining movable armies."
  @spec spend_action(Engine.game()) :: Engine.game()
  def spend_action(game) do
    game =
      if game.turn_party == game.human,
        do: %{game | total_human_moves: game.total_human_moves + 1},
        else: game

    game = %{game | turn_moves_spent: game.turn_moves_spent + 1}
    actions = max(0, game.actions - 1)
    actions = min(actions, length(State.movable_armies(game)))
    %{game | actions: actions}
  end

  defp battle_scar(game) do
    {_, rng} = Rng.next_int(game.rng, 2)
    {_, rng} = Rng.next_int(rng, 2)
    {_, rng} = Rng.next_int(rng, 360)

    rng =
      Enum.reduce(1..15, rng, fn _, r ->
        {_, r} = Rng.next_int(r, 6)
        {_, r} = Rng.next_int(r, 50)
        {_, r} = Rng.next_int(r, 40)
        r
      end)

    %{game | rng: rng}
  end

  defp battle_msg(_game, army, defender, :attacker) do
    "#{Config.faction_name(army.party)} defeated #{Config.faction_name(defender.party)} (#{army.count} left)"
  end

  defp battle_msg(_game, army, defender, :defender) do
    "#{Config.faction_name(defender.party)} repelled #{Config.faction_name(army.party)} (#{defender.count} left)"
  end
end
