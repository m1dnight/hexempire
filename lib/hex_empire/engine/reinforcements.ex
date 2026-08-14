defmodule HexEmpire.Engine.Reinforcements do
  @moduledoc """
  Port of original/reinforcements.js spawnUnits (cheat branches dead):

  * producers = the party's towns (derived list, board order); ports join when
    the portsGenerateTroops rule is on.
  * ucount = floor((lands + 5*ports) / max(1, producers))
  * capitals pass: every capital held by the party gets +5 (capital index order)
  * producers pass: every producer gets +(5 + ucount)
  * incoming morale = existing army's morale, else the faction morale average.
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.{Army, Config}

  @doc "spawnUnits for `party` (see the moduledoc for the exact pass order)."
  @spec spawn_units(Engine.game(), Engine.party()) :: Engine.game()
  def spawn_units(game, party) do
    towns = Enum.at(game.towns_by_party, party)
    ports = Enum.at(game.ports_by_party, party)
    lands = Enum.at(game.lands_by_party, party)

    producing_ports = if Config.has_rule?(game, :ports_generate_troops), do: ports, else: []

    producers = Enum.uniq(towns ++ producing_ports)

    ucount = div(length(lands) + length(ports) * 5, max(1, length(producers)))

    game =
      Enum.reduce(game.capitals, game, fn cap_key, g ->
        case cap_key && Map.fetch!(g.fields, cap_key) do
          %{party: ^party} -> reinforce(g, cap_key, party, 5)
          _ -> g
        end
      end)

    Enum.reduce(producers, game, fn key, g ->
      reinforce(g, key, party, 5 + ucount)
    end)
  end

  defp reinforce(game, field_key, party, count) do
    field = Map.fetch!(game.fields, field_key)

    morale =
      case field.army do
        nil -> Enum.at(game.morale, party)
        army -> army.morale
      end

    {game, _army} = Army.join(game, field_key, party, count, morale)
    game
  end
end
