defmodule HexEmpire.Engine.Field do
  @moduledoc """
  A board field (hex) — the shape produced by `HexEmpire.Engine.Generator`.

  `party`/`capital` are -1 when neutral/not a capital; `neighbours` holds the
  six neighbour keys in the original's direction order (nil off-board — the
  order is load-bearing, see `HexEmpire.Engine.Hex`). The embedded `army` is
  a `HexEmpire.Engine.Army` struct or nil.
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.Army

  @enforce_keys [:key, :x, :y, :type]
  defstruct [
    :key,
    :x,
    :y,
    :type,
    party: -1,
    capital: -1,
    estate: nil,
    army: nil,
    land_id: -1,
    neighbours: [],
    town_name: ""
  ]

  @typedoc "A board field. `party`/`capital` are -1 when neutral/not a capital."
  @type t :: %__MODULE__{
          key: Engine.field_key(),
          x: non_neg_integer(),
          y: non_neg_integer(),
          type: :land | :water,
          party: -1 | Engine.party(),
          capital: -1 | Engine.party(),
          estate: nil | :town | :port,
          army: Army.t() | nil,
          land_id: integer(),
          neighbours: [Engine.field_key() | nil],
          town_name: String.t()
        }
end
