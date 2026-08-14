defmodule HexEmpire.Engine.Morale do
  @moduledoc """
  Port of original/morale.js (cheat branches omitted — cheats module is absent
  from the source drop and always disabled).
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.Army

  @doc "addMorale on a bare army map: morale = min(count, max(0, morale + amount))."
  @spec add(Army.t(), integer()) :: Army.t()
  def add(army, amount) do
    %{army | morale: army.morale |> Kernel.+(amount) |> max(0) |> min(army.count)}
  end

  @doc """
  addMoraleForAll: apply to every army of `party` (no-op when amount == 0).

  STALE-LIST SEMANTICS (load-bearing, matches the original): iterates the army
  IDS captured by the last update_derived (`armies_by_party`), resolved to their
  CURRENT fields via army_pos. Armies created since the last update_derived
  (e.g. an overflow-split leftover, a liberation garrison) are NOT in the list
  and correctly miss the award; armies that died since are skipped.
  """
  @spec add_for_all(Engine.game(), integer(), Engine.party()) :: Engine.game()
  def add_for_all(game, amount, party)
  def add_for_all(game, 0, _party), do: game

  def add_for_all(game, amount, party) do
    Enum.reduce(Enum.at(game.armies_by_party, party), game, fn id, g ->
      case Map.get(g.army_pos, id) do
        nil ->
          g

        key ->
          case Map.fetch!(g.fields, key).army do
            %{id: ^id} = army -> Army.put_army(g, key, add(army, amount))
            _ -> g
          end
      end
    end)
  end

  @doc "addMoraleAwards([all, self], army_at_key): self first, then party-wide."
  @spec add_awards(Engine.game(), {integer(), integer()}, Engine.field_key()) :: Engine.game()
  def add_awards(game, {all, self}, field_key) do
    field = Map.fetch!(game.fields, field_key)
    army = add(field.army, self)
    game = Army.put_army(game, field_key, army)
    add_for_all(game, all, army.party)
  end

  @doc """
  refreshFactionMorale: every army of a party gets a morale floor of
  floor(totalCount/50); faction morale = floor(avg army morale) or 10 if none.
  Must run AFTER total_count is derived (the original calls it inside
  updateDerived after listArmies).
  """
  @spec refresh_faction(Engine.game()) :: Engine.game()
  def refresh_faction(game) do
    Enum.reduce(0..3, game, fn party, g ->
      floor_val = div(Enum.at(g.total_count, party), 50)
      ids = Enum.at(g.armies_by_party, party)

      {g, sum} =
        Enum.reduce(ids, {g, 0}, fn id, {acc, sum} ->
          key = Map.fetch!(acc.army_pos, id)
          army = Map.fetch!(acc.fields, key).army

          army =
            if army.morale < floor_val,
              do: %{army | morale: min(army.count, floor_val)},
              else: army

          {Army.put_army(acc, key, army), sum + army.morale}
        end)

      len = length(ids)
      faction_morale = if len > 0, do: div(sum, len), else: 10

      %{g | morale: List.replace_at(g.morale, party, faction_morale)}
    end)
  end
end
