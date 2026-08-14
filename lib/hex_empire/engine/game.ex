defmodule HexEmpire.Engine.Game do
  @moduledoc """
  The full game state — created by `HexEmpire.Engine.State.create_game/1` and
  threaded through every engine call. See `create_game` for the authoritative
  initial values (this struct's defaults only serve bare test fixtures built
  with `struct!/2`).

  The `rng` field is the shared LCG seed; the `*_by_party` lists are derived
  state rebuilt by `State.update_derived/1` as needed.
  """

  alias HexEmpire.Engine

  defstruct [
    :seed,
    :winner,
    :victory_reason,
    :ai_trace,
    rng: 0,
    fields: %{},
    field_order: [],
    capitals: [],
    # immutable 2-ring topology precomputed by the Generator (AI hot path)
    ring2: %{},
    screen: :game,
    human: 0,
    difficulty: 5,
    rules: %{},
    game_mode: :standard,
    spectating: false,
    status: [1, 1, 1, 1],
    morale: [10, 10, 10, 10],
    # derived (rebuilt by State.update_derived)
    armies_by_party: [[], [], [], []],
    army_pos: %{},
    total_count: [0, 0, 0, 0],
    total_power: [0, 0, 0, 0],
    towns_by_party: [[], [], [], []],
    ports_by_party: [[], [], [], []],
    lands_by_party: [[], [], [], []],
    province_capitals: [[], [], [], []],
    human_condition: 1,
    # turn state
    turn_party: 0,
    turns: 0,
    actions: 0,
    turn_moves_spent: 0,
    total_human_moves: 0,
    speech_given: [false, false, false, false],
    message: "",
    log: [],
    next_army_id: 1,
    # AI cross-turn state
    wait_support_field: [nil, nil, nil, nil],
    wait_support_count: [0, 0, 0, 0],
    original_capitals_remaining: 4
  ]

  @typedoc "The full game state (see the moduledoc)."
  @type t :: %__MODULE__{
          seed: integer() | nil,
          rng: integer(),
          fields: %{Engine.field_key() => Engine.field()},
          field_order: [Engine.field_key()],
          capitals: [Engine.field_key() | nil],
          ring2: %{Engine.field_key() => [Engine.field_key()]},
          screen: :game | :victory | :defeat | :spectator_victory,
          human: integer(),
          difficulty: integer(),
          rules: Engine.rules() | %{},
          game_mode: :standard,
          spectating: boolean(),
          status: [non_neg_integer()],
          morale: [non_neg_integer()],
          armies_by_party: [[pos_integer()]],
          army_pos: %{pos_integer() => Engine.field_key()},
          total_count: [non_neg_integer()],
          total_power: [non_neg_integer()],
          towns_by_party: [[Engine.field_key()]],
          ports_by_party: [[Engine.field_key()]],
          lands_by_party: [[Engine.field_key()]],
          province_capitals: [[Engine.field_key()]],
          human_condition: 0..3,
          turn_party: Engine.party(),
          turns: non_neg_integer(),
          actions: non_neg_integer(),
          turn_moves_spent: non_neg_integer(),
          total_human_moves: non_neg_integer(),
          speech_given: [boolean()],
          winner: Engine.party() | nil,
          victory_reason: String.t() | nil,
          message: String.t(),
          log: [String.t()],
          next_army_id: pos_integer(),
          wait_support_field: [Engine.field_key() | nil],
          wait_support_count: [non_neg_integer()],
          original_capitals_remaining: non_neg_integer(),
          ai_trace: map() | nil
        }
end
