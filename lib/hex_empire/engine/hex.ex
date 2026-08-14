defmodule HexEmpire.Engine.Hex do
  @moduledoc """
  Port of original/hex.js — column-offset hex grid (x = column, y = row),
  even/odd column parity determines the neighbour offsets. Neighbour ORDER is
  load-bearing (annexLand flips in direction order; the generation pathfinder
  scans directions 0..5).
  """

  alias HexEmpire.Engine

  @doc "The canonical field key for grid coordinates: `\"f<x>x<y>\"`."
  @spec field_key(integer(), integer()) :: Engine.field_key()
  def field_key(x, y), do: "f#{x}x#{y}"

  @doc "The six neighbour coordinates in the original's direction order."
  @spec neighbour_coordinates(integer(), integer()) :: [{integer(), integer()}]
  def neighbour_coordinates(x, y) do
    if rem(x, 2) == 0 do
      [{x + 1, y}, {x, y + 1}, {x - 1, y}, {x - 1, y - 1}, {x, y - 1}, {x + 1, y - 1}]
    else
      [{x + 1, y + 1}, {x, y + 1}, {x - 1, y + 1}, {x - 1, y}, {x, y - 1}, {x + 1, y}]
    end
  end

  @doc """
  originalDistance: Euclidean distance on the doubled grid
  (ax = x*5, ay = y*10 + (odd column ? 5 : 0)).
  """
  @spec original_distance(Engine.field(), Engine.field()) :: float()
  def original_distance(a, b) do
    ax = a.x * 5
    bx = b.x * 5
    ay = a.y * 10 + if(rem(a.x, 2) != 0, do: 5, else: 0)
    by = b.y * 10 + if(rem(b.x, 2) != 0, do: 5, else: 0)
    dx = ax - bx
    dy = ay - by
    :math.sqrt(dx * dx + dy * dy)
  end

  @doc """
  furtherNeighbours: ring-1 fields (in direction order), then their neighbours
  (in encounter order), deduped, excluding the field itself. Returns keys.
  `fields` is the game's field map (key => field with .neighbours list of key|nil).
  """
  @spec further_neighbours(%{Engine.field_key() => Engine.field()}, Engine.field_key()) ::
          [Engine.field_key()]
  def further_neighbours(fields, key) do
    field = Map.fetch!(fields, key)

    # Order-preserving dedup matching the JS Set (a field never neighbours
    # itself and its six neighbour keys are distinct, so uniq is a no-op kept
    # for fidelity with the Set semantics).
    ring1 = field.neighbours |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {ring2, _seen} =
      Enum.reduce(ring1, {[], MapSet.new([key | ring1])}, fn n, {acc, seen} ->
        nf = Map.fetch!(fields, n)

        Enum.reduce(nf.neighbours, {acc, seen}, fn n2, {a, s} ->
          if n2 == nil or MapSet.member?(s, n2), do: {a, s}, else: {[n2 | a], MapSet.put(s, n2)}
        end)
      end)

    ring1 ++ Enum.reverse(ring2)
  end
end
