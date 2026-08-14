defmodule HexEmpire.Engine.Config do
  @moduledoc """
  Exact constants from original/config.js and rules.js.
  """

  alias HexEmpire.Engine

  # MAP
  @spec columns() :: pos_integer()
  def columns, do: 20

  @spec rows() :: pos_integer()
  def rows, do: 11

  # FACTIONS (id order matters everywhere)
  @spec factions() :: [
          %{id: Engine.party(), name: String.t(), color: String.t(), dark: String.t()}
        ]
  def factions do
    [
      %{id: 0, name: "Redosia", color: "#ff0000", dark: "#8b0000"},
      %{id: 1, name: "Violetnam", color: "#ff00ff", dark: "#790079"},
      %{id: 2, name: "Bluegaria", color: "#00bbff", dark: "#005b8b"},
      %{id: 3, name: "Greenland", color: "#00ff00", dark: "#087b08"}
    ]
  end

  # RULES (config.js)
  @spec max_actions() :: pos_integer()
  def max_actions, do: 5

  @spec max_army() :: pos_integer()
  def max_army, do: 99

  @spec starting_morale() :: pos_integer()
  def starting_morale, do: 10

  @spec default_difficulty() :: pos_integer()
  def default_difficulty, do: 5

  @spec status_names() :: [String.t()]
  def status_names, do: ["Province", "Kingdom", "Empire", "Empire", "Empire"]

  @doc "The display name of a faction (party index 0..3)."
  @spec faction_name(Engine.party()) :: String.t()
  def faction_name(party) do
    Enum.at(factions(), party).name
  end

  # DEFAULT_RULE_STATE (rules.js)
  @spec default_rules() :: Engine.rules()
  def default_rules do
    %{
      ports_generate_troops: false,
      moves_per_turn: max_actions(),
      move_distance: 2,
      open_water: false,
      battle_luck: false,
      fast_enemy_turns: false,
      domination_points: 5
    }
  end

  @doc """
  hasRule(game, key) — boolean rule lookup on the game's rule state.

  The `!!` truthiness coercion is intentional: rules also hold non-boolean
  values (`domination_points: 5`, `moves_per_turn: 5`), and the JS hasRule is
  a truthiness check — so e.g. `has_rule?(game, :domination_points)` is true,
  matching the original.
  """
  @spec has_rule?(Engine.game(), atom()) :: boolean()
  def has_rule?(game, key), do: !!Map.get(game.rules, key)
end
