defmodule HexEmpire.Engine.Query do
  @moduledoc """
  The read-side API for AI players (and anything else that inspects a game).

  Every function is pure and side-effect free. AI algorithms should be
  expressible in this vocabulary alone — if an AI needs to reach into raw
  engine structs, the missing query belongs here.

  Terminology:
    * an "army ref" is `{field_key, %Army{}}` — where it stands and what it is
    * "power" is the combat number: `count + morale`
    * combat here is DETERMINISTIC — `predict_attack/3` returns the exact
      outcome the engine would produce (the engine's RNG draws only feed
      cosmetic battle art, never the result).
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.{Config, Hex, Movement, Pathfinding, State}

  # ---------------------------------------------------------------------------
  # Armies
  # ---------------------------------------------------------------------------

  @doc "The party's armies still able to move this turn, in board order."
  @spec movable_armies(Engine.game(), Engine.party()) :: [Engine.field_key()]
  defdelegate movable_armies(game, party), to: State

  @doc "The army standing on `key`, or nil."
  @spec army_at(Engine.game(), Engine.field_key()) :: Engine.army() | nil
  def army_at(game, key), do: Map.fetch!(game.fields, key).army

  @doc "The field at `key`."
  @spec field(Engine.game(), Engine.field_key()) :: Engine.field()
  def field(game, key), do: Map.fetch!(game.fields, key)

  @doc "Combat power of an army (or of the army on a field key): count + morale."
  @spec power(Engine.army() | nil) :: non_neg_integer()
  def power(nil), do: 0
  def power(army), do: army.count + army.morale

  @doc "Total power of a party's whole force (from the last derived state)."
  @spec total_power(Engine.game(), Engine.party()) :: non_neg_integer()
  def total_power(game, party), do: Enum.at(game.total_power, party)

  @doc "Total troop count of a party."
  @spec total_count(Engine.game(), Engine.party()) :: non_neg_integer()
  def total_count(game, party), do: Enum.at(game.total_count, party)

  # ---------------------------------------------------------------------------
  # Movement
  # ---------------------------------------------------------------------------

  @doc """
  All fields the army on `key` may move to this turn (movement rules applied:
  distance 2, ports for sea travel, merge/attack legality), in the engine's
  stable BFS order.
  """
  @spec moves(Engine.game(), Engine.field_key()) :: [Engine.field_key()]
  def moves(game, key), do: Movement.possible_moves(game, key, true)

  # ---------------------------------------------------------------------------
  # Geometry
  # ---------------------------------------------------------------------------

  @doc "The original's board distance between two fields (Euclidean on the doubled grid)."
  @spec distance(Engine.game(), Engine.field_key(), Engine.field_key()) :: float()
  def distance(game, a, b), do: Hex.original_distance(field(game, a), field(game, b))

  @doc "Field keys within two steps of `key` (precomputed ring, stable order)."
  @spec ring2(Engine.game(), Engine.field_key()) :: [Engine.field_key()]
  def ring2(game, key), do: Map.fetch!(game.ring2, key)

  @doc """
  Walking path from `from` to `to` under gameplay movement rules (land routes,
  sea only through ports), as a list of field keys including both ends;
  nil when unreachable. Length is the original AI's "capital gradient" metric.
  """
  @spec path(Engine.game(), Engine.field_key(), Engine.field_key()) ::
          [Engine.field_key()] | nil
  def path(game, from, to), do: Pathfinding.find_path(game.fields, from, to, [], true)

  # ---------------------------------------------------------------------------
  # Strategic landmarks
  # ---------------------------------------------------------------------------

  @doc "The four original capital field keys, indexed by founding party (nil-safe)."
  @spec capitals(Engine.game()) :: [Engine.field_key() | nil]
  def capitals(game), do: game.capitals

  @doc "Capitals currently held by their original founder AND hostile to `party`."
  @spec enemy_home_capitals(Engine.game(), Engine.party()) ::
          [{Engine.party(), Engine.field_key()}]
  def enemy_home_capitals(game, party) do
    for {cap_key, p} <- Enum.with_index(game.capitals),
        p != party,
        cap_key != nil,
        field(game, cap_key).party == p,
        do: {p, cap_key}
  end

  @doc "Aggregate friendly power on the two rings around `key` (the army on `key` included)."
  @spec friendly_power_near(Engine.game(), Engine.party(), Engine.field_key()) ::
          non_neg_integer()
  def friendly_power_near(game, party, key) do
    ring2(game, key)
    |> Enum.reduce(0, fn k, acc ->
      case army_at(game, k) do
        %{party: ^party} = a -> acc + power(a)
        _ -> acc
      end
    end)
  end

  @doc "Aggregate hostile power on the two rings around `key`."
  @spec enemy_power_near(Engine.game(), Engine.party(), Engine.field_key()) ::
          non_neg_integer()
  def enemy_power_near(game, party, key) do
    ring2(game, key)
    |> Enum.reduce(0, fn k, acc ->
      case army_at(game, k) do
        nil -> acc
        a -> if a.party != party, do: acc + power(a), else: acc
      end
    end)
  end

  @doc "Does any field within two steps of `key` satisfy `pred`?"
  @spec near?(Engine.game(), Engine.field_key(), (Engine.field() -> boolean())) :: boolean()
  def near?(game, key, pred) do
    Enum.any?(ring2(game, key), fn k -> pred.(field(game, k)) end)
  end

  # ---------------------------------------------------------------------------
  # Combat forecasting (deterministic!)
  # ---------------------------------------------------------------------------

  @doc """
  Exact outcome if the army on `from` attacked the army on `to` right now:

    * `{:attacker_wins, remaining_count}` — defender annihilated, attacker
      captures the field with `remaining_count` troops
    * `{:defender_holds, remaining_count}` — attacker annihilated, defender
      keeps the field with `remaining_count` troops (ties favor the defender)

  Mirrors Combat.resolve arithmetic without touching the game (luck rule off,
  as in every standard game).
  """
  @spec predict_attack(Engine.game(), Engine.field_key(), Engine.field_key()) ::
          {:attacker_wins, pos_integer()} | {:defender_holds, pos_integer()} | :no_battle
  def predict_attack(game, from, to) do
    attacker = army_at(game, from)
    defender = army_at(game, to)

    if attacker == nil or defender == nil or attacker.party == defender.party do
      :no_battle
    else
      ap = power(attacker)
      dp = power(defender)

      if ap > dp do
        {:attacker_wins, max(1, attacker.count - trunc(:math.floor(dp / ap * attacker.count)))}
      else
        {:defender_holds, max(1, defender.count - trunc(:math.floor(ap / dp * attacker.count)))}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Economy
  # ---------------------------------------------------------------------------

  @doc "Troops per turn the party currently receives (capitals, cities, land/port bonus)."
  @spec income(Engine.game(), Engine.party()) :: non_neg_integer()
  def income(game, party) do
    towns = Enum.at(game.towns_by_party, party)
    ports = Enum.at(game.ports_by_party, party)
    lands = Enum.at(game.lands_by_party, party)

    capitals =
      Enum.count(game.capitals, fn key -> key != nil and field(game, key).party == party end)

    ucount = div(length(lands) + length(ports) * 5, max(1, length(towns)))
    capitals * 5 + length(towns) * (5 + ucount)
  end

  @doc "Board-wide config constants an AI may want."
  @spec max_army() :: pos_integer()
  defdelegate max_army(), to: Config
end
