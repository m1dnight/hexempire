defmodule HexEmpire.Engine do
  @moduledoc """
  The single public API of the Hex Empire game engine.

  ## FREEZE POLICY — read before touching anything under `HexEmpire.Engine.*`

  The engine is a **bit-exact port** of the original Hex Empire JS engine and
  its behavior is **frozen**: it is verified by the golden replay suite
  (`test/hex_empire/engine/replay_test.exs` against `test/golden/`), which
  replays full games and asserts identical RNG state, armies, fields, morale
  and winners after every turn. Iteration order, arithmetic, RNG draw order,
  and the documented quirks in the internal modules are **load-bearing** —
  preserve them (and their comments) through any refactor. See the README for
  the porting contract.

  Callers outside the engine (the web layer, session contexts, scripts) must
  go through this module only and never alias `HexEmpire.Engine.*` internals.

  ## Types

  The game, its fields and armies are structs — `HexEmpire.Engine.Game`,
  `HexEmpire.Engine.Field` and `HexEmpire.Engine.Army` (see `t:game/0`,
  `t:field/0`, `t:army/0`). Armies live embedded in their field
  (`field.army`); fields are addressed by string keys (`"f<x>x<y>"`) in
  `game.fields`, with board order given by `game.field_order`.
  """

  alias HexEmpire.Engine.{Actions, Ai, Config, Movement, OriginalAi, State}

  @typedoc "A field key, `\"f<x>x<y>\"` (see `HexEmpire.Engine.Hex.field_key/2`)."
  @type field_key :: String.t()

  @typedoc "A faction/party index (Redosia 0, Violetnam 1, Bluegaria 2, Greenland 3)."
  @type party :: 0..3

  @typedoc "An army, embedded in its field (`field.army`)."
  @type army :: HexEmpire.Engine.Army.t()

  @typedoc "A board field. `party`/`capital` are -1 when neutral/not a capital."
  @type field :: HexEmpire.Engine.Field.t()

  @typedoc "The rule state (see `HexEmpire.Engine.Config.default_rules/0`)."
  @type rules :: %{
          ports_generate_troops: boolean(),
          moves_per_turn: pos_integer(),
          move_distance: pos_integer(),
          open_water: boolean(),
          battle_luck: boolean(),
          fast_enemy_turns: boolean(),
          domination_points: pos_integer()
        }

  @typedoc """
  The full game state — a `%HexEmpire.Engine.Game{}` struct created by
  `new_game/1` and threaded through every engine call.
  """
  @type game :: HexEmpire.Engine.Game.t()

  @typedoc """
  The outcome of a move: `:attacker` (moved/won the battle), `:defender`
  (attack repelled), or `:merge` (joined a friendly stack). Battle results
  carry extra diagnostic keys (powers/luck).
  """
  @type move_result :: %{
          required(:winner) => :attacker | :defender | :merge,
          optional(atom()) => term()
        }

  # ---------------------------------------------------------------------------
  # Game lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Create a new game. Options: `:seed` (required), `:human` (default 0),
  `:difficulty` (default #{Config.default_difficulty()}), `:rules` (merged
  over the defaults).
  """
  @spec new_game(keyword()) :: game()
  defdelegate new_game(opts), to: State, as: :create_game

  @doc """
  End the current party's turn: cleanup (moved flags reset, idle armies lose
  morale), reinforcements spawn, and the next living party's turn begins.
  """
  @spec end_turn(game()) :: game()
  defdelegate end_turn(game), to: State, as: :finish_turn

  # ---------------------------------------------------------------------------
  # Moves
  # ---------------------------------------------------------------------------

  @doc """
  All fields the army on `field_key` may move to, in the original push order.
  `no_self` omits the origin from the result (UI and AI both pass `true`).
  """
  @spec possible_moves(game(), field_key(), boolean()) :: [field_key()]
  defdelegate possible_moves(game, field_key, no_self \\ false), to: Movement

  @doc """
  Move the army on `from_key` to `to_key` (must be validated against
  `possible_moves/3`) and spend one action — the exact sequence every caller
  of the engine uses. Returns `{game, result}` so callers can inspect the
  battle outcome.
  """
  @spec move(game(), field_key(), field_key()) :: {game(), move_result()}
  def move(game, from_key, to_key) do
    {game, result} = Actions.move_army(game, from_key, to_key)
    {Actions.spend_action(game), result}
  end

  @doc "Field keys of the party's unmoved armies (current turn party by default)."
  @spec movable_armies(game(), party() | nil) :: [field_key()]
  defdelegate movable_armies(game, party \\ nil), to: State

  # ---------------------------------------------------------------------------
  # AI
  # ---------------------------------------------------------------------------

  @doc """
  Perform a single AI action for the current turn party (rank all moves, apply
  the best, spend an action). Returns `{game, result | nil}` — `nil` when the
  AI had no move (its action budget is zeroed in that case).

  The optional `ai` module selects the player: `OriginalAi` (default — the
  classic, golden-verified opponent) or any `HexEmpire.Engine.Ai`
  implementation such as `TurnPlannerAi` (the "Brutal" difficulty).
  """
  @spec ai_step(game(), module()) :: {game(), move_result() | nil}
  def ai_step(game, ai \\ OriginalAi), do: ai.play_action(game)

  @doc "Play the current AI party's whole turn at once (no turn finish)."
  @spec ai_turn(game(), module()) :: game()
  def ai_turn(game, ai \\ OriginalAi), do: Ai.play_turn(game, ai)

  # ---------------------------------------------------------------------------
  # Display data
  # ---------------------------------------------------------------------------

  @doc "The display name of a faction (party index 0..3)."
  @spec faction_name(party()) :: String.t()
  defdelegate faction_name(party), to: Config

  @doc "The four factions in id order (`%{id, name, color, dark}`)."
  @spec factions() :: [%{id: party(), name: String.t(), color: String.t(), dark: String.t()}]
  defdelegate factions(), to: Config

  @doc "Status display names indexed by the game's per-party status value."
  @spec status_names() :: [String.t()]
  defdelegate status_names(), to: Config
end
