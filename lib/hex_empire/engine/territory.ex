defmodule HexEmpire.Engine.Territory do
  @moduledoc """
  Port of original/territory.js annexLand — exact order:

  1. guards (needs an army unless startup; land only)
  2. former-owner morale penalty (0 own capital / -30 capital / -10 town / -5 port)
  3. capital-liberation recursion: when the FORMER owner's original capital is
     taken and they hold captured "province" capitals, each reverts to its
     original faction with a fresh 99/99 army (startup annex)
  4. conqueror morale awards ([50,30] recaptured own capital, [30,20] enemy
     capital, [10,10] town, [5,5] port, [1,0] land) — self first, then party
  5. ownership flip; then neighbour flip in direction order (land, no estate,
     no army) with per-neighbour awards
  6. victory checks (spectator: sole capital controller; human: capital lost →
     annexer wins; human holds all enemy original capitals → human wins)
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.{Army, Morale, State}

  @doc """
  annexLand(party, field, game, {startup}) — `party` annexes `field_key`
  (guards: an army must be present unless `startup: true`; land only).
  `startup: true` is the capital-liberation garrison placement: it skips the
  army-required guard and all morale awards. Returns the updated game,
  possibly with a winner set by the victory checks.
  """
  @spec annex_land(Engine.game(), Engine.party(), Engine.field_key(), keyword()) :: Engine.game()
  def annex_land(game, party, field_key, opts \\ []) do
    startup = Keyword.get(opts, :startup, false)
    field = Map.fetch!(game.fields, field_key)

    cond do
      field.army == nil and not startup -> game
      field.type != :land -> game
      true -> do_annex(game, party, field_key, startup)
    end
  end

  defp do_annex(game, party, field_key, startup) do
    field = Map.fetch!(game.fields, field_key)
    former = field.party

    # Former-owner penalty + capital liberation
    game =
      if former >= 0 and former != party do
        game = Morale.add_for_all(game, lost(former, field), former)

        if field.capital == former and Enum.at(game.province_capitals, former) != [] do
          Enum.reduce(Enum.at(game.province_capitals, former), game, fn province_key, g ->
            province = Map.fetch!(g.fields, province_key)
            g = Army.put_army(g, province_key, nil)
            {g, _} = Army.create(g, province_key, province.capital, 99, 99)
            annex_land(g, province.capital, province_key, startup: true)
          end)
        else
          game
        end
      else
        game
      end

    # Conqueror awards (non-startup captures only)
    game =
      if not startup and former != party do
        field = Map.fetch!(game.fields, field_key)
        Morale.add_awards(game, earned(field), field_key)
      else
        game
      end

    # Ownership flip
    game = %{game | fields: Map.update!(game.fields, field_key, &%{&1 | party: party})}

    # Neighbour flip in direction order
    field = Map.fetch!(game.fields, field_key)

    game =
      Enum.reduce(field.neighbours, game, fn n, g ->
        case n && Map.fetch!(g.fields, n) do
          %{type: :land, estate: nil, army: nil} = nf ->
            g =
              if not startup and nf.party != party,
                do: Morale.add_awards(g, earned(nf), field_key),
                else: g

            %{g | fields: Map.update!(g.fields, n, &%{&1 | party: party})}

          _ ->
            g
        end
      end)

    victory_checks(game, party)
  end

  defp victory_checks(game, party) do
    if game.spectating or game.human < 0 do
      case State.capital_controller_winner(game) do
        nil -> game
        winner -> State.set_game_winner(game, winner, "capital")
      end
    else
      human_capital_key = Enum.at(game.capitals, game.human)
      human_capital = human_capital_key && Map.fetch!(game.fields, human_capital_key)

      if human_capital == nil or human_capital.party != game.human do
        State.set_game_winner(game, party, "capital")
      else
        original_capitals =
          game.capitals |> Enum.reject(&is_nil/1) |> Enum.map(&Map.fetch!(game.fields, &1))

        enemy_count = Enum.count(original_capitals, &(&1.capital != game.human))

        captured_count =
          Enum.count(original_capitals, &(&1.party == game.human and &1.capital != game.human))

        if party == game.human and enemy_count > 0 and captured_count >= enemy_count do
          State.set_game_winner(game, party, "capital")
        else
          game
        end
      end
    end
  end

  # earned(field): [party-wide, self] morale award
  defp earned(field) do
    cond do
      field.capital >= 0 and field.capital == field.party -> {50, 30}
      field.capital >= 0 -> {30, 20}
      field.estate == :town -> {10, 10}
      field.estate == :port -> {5, 5}
      field.type == :land -> {1, 0}
      true -> {0, 0}
    end
  end

  # lost(party, field): penalty to the former owner's whole party
  defp lost(party, field) do
    cond do
      field.capital == party -> 0
      field.capital >= 0 -> -30
      field.estate == :town -> -10
      field.estate == :port -> -5
      true -> 0
    end
  end
end
