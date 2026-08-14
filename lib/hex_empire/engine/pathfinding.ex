defmodule HexEmpire.Engine.Pathfinding do
  @moduledoc """
  Port of original/pathfinding.js — both pathfinders, quirks preserved:

  * `find_path/5` — the gameplay A*-ish search: linear scan for the best open
    node by g + originalDistance (strict <, first-lowest wins), closed set
    checked after pop, `g >= best` prune, target exempt from canWalk.
  * `find_original_generation_path/5` — the SWF port-generation pathfinder:
    FIFO open list with a single front-swap of the lowest `5 + distance`
    priority (non-cumulative), no reprioritisation, cheaper-closed replacement,
    the empty-open-list null quirk, and reconstruction through closedIndex.

  Fields are addressed by key into the `fields` map; each field has
  `.neighbours` (list of key|nil in direction order), `.type`, `.estate`, `.x`, `.y`.
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.Hex

  @typedoc "The game's field map, `key => field`."
  @type fields :: %{Engine.field_key() => Engine.field()}

  @doc "canWalk(a, b): may a step from `a` enter `b`?"
  @spec can_walk(
          fields(),
          Engine.field_key() | nil,
          Engine.field_key() | nil,
          [atom()],
          boolean()
        ) ::
          boolean()
  def can_walk(_fields, nil, _b, _avoid, _avoid_water), do: false
  def can_walk(_fields, _a, nil, _avoid, _avoid_water), do: false

  def can_walk(fields, a_key, b_key, avoid_estate, avoid_water) do
    a = Map.fetch!(fields, a_key)
    b = Map.fetch!(fields, b_key)

    cond do
      b.estate in avoid_estate -> false
      not avoid_water -> true
      a.type == b.type -> true
      a.type == :water and b.type == :land -> true
      true -> b.type == :water and a.estate == :port
    end
  end

  # ---------------------------------------------------------------------------
  # findPath — gameplay pathfinder
  # ---------------------------------------------------------------------------

  @doc """
  findPath: the gameplay pathfinder (see the moduledoc for its quirks).
  Returns the list of field keys from `start_key` to `end_key` inclusive, or
  nil when unreachable (or when either endpoint is nil).
  """
  @spec find_path(
          fields(),
          Engine.field_key() | nil,
          Engine.field_key() | nil,
          [atom()],
          boolean()
        ) ::
          [Engine.field_key()] | nil
  def find_path(fields, start_key, end_key, avoid_estate \\ [], avoid_water \\ true)
  def find_path(_fields, nil, _e, _av, _aw), do: nil
  def find_path(_fields, _s, nil, _av, _aw), do: nil

  def find_path(fields, start_key, end_key, avoid_estate, avoid_water) do
    avoid_water = if Map.fetch!(fields, start_key).type == :water, do: false, else: avoid_water
    end_field = Map.fetch!(fields, end_key)

    open = [%{key: start_key, g: 0, parent: nil}]
    best = %{start_key => 0}
    fp_loop(fields, open, best, MapSet.new(), end_key, end_field, avoid_estate, avoid_water)
  end

  defp fp_loop(_fields, [], _best, _closed, _ek, _ef, _av, _aw), do: nil

  defp fp_loop(fields, open, best, closed, end_key, end_field, avoid_estate, avoid_water) do
    # linear scan: strictly-lower f wins, first index kept on ties
    {bi, _} =
      open
      |> Enum.with_index()
      |> Enum.reduce({0, nil}, fn {node, i}, {best_i, best_f} ->
        f = node.g + Hex.original_distance(Map.fetch!(fields, node.key), end_field)

        cond do
          best_f == nil -> {i, f}
          f < best_f -> {i, f}
          true -> {best_i, best_f}
        end
      end)

    {node, open} = List.pop_at(open, bi)

    cond do
      node.key == end_key ->
        reconstruct_fp(node)

      MapSet.member?(closed, node.key) ->
        fp_loop(fields, open, best, closed, end_key, end_field, avoid_estate, avoid_water)

      true ->
        closed = MapSet.put(closed, node.key)
        field = Map.fetch!(fields, node.key)

        {open, best} =
          Enum.reduce(field.neighbours, {open, best}, fn next, {o, b} ->
            cond do
              next == nil ->
                {o, b}

              next != end_key and not can_walk(fields, node.key, next, avoid_estate, avoid_water) ->
                {o, b}

              true ->
                g = node.g + 5

                if g >= Map.get(b, next, :infinity) do
                  {o, b}
                else
                  {o ++ [%{key: next, g: g, parent: node}], Map.put(b, next, g)}
                end
            end
          end)

        fp_loop(fields, open, best, closed, end_key, end_field, avoid_estate, avoid_water)
    end
  end

  # Walking parents from the end node while prepending yields start..end order.
  defp reconstruct_fp(node), do: reconstruct_fp(node, [])

  defp reconstruct_fp(nil, acc), do: acc
  defp reconstruct_fp(node, acc), do: reconstruct_fp(node.parent, [node.key | acc])

  # ---------------------------------------------------------------------------
  # findOriginalGenerationPath — SWF generation pathfinder
  # ---------------------------------------------------------------------------

  @doc """
  findOriginalGenerationPath: the SWF port-generation pathfinder (see the
  moduledoc for its quirks). Returns the list of field keys from `start_key`
  to `end_key` inclusive, or nil when unreachable — including via the
  original's empty-open-list and reconstruct-through-closedIndex quirks.
  """
  @spec find_original_generation_path(
          fields(),
          Engine.field_key() | nil,
          Engine.field_key() | nil,
          [atom()],
          boolean()
        ) :: [Engine.field_key()] | nil
  def find_original_generation_path(
        fields,
        start_key,
        end_key,
        avoid_estate \\ [],
        avoid_water \\ true
      )

  def find_original_generation_path(_f, nil, _e, _av, _aw), do: nil
  def find_original_generation_path(_f, _s, nil, _av, _aw), do: nil

  def find_original_generation_path(fields, start_key, end_key, avoid_estate, avoid_water) do
    avoid_water = if Map.fetch!(fields, start_key).type == :water, do: false, else: avoid_water
    end_field = Map.fetch!(fields, end_key)

    state = %{
      # open: list of nodes %{key, g, parent_key, priority}
      open: [%{key: start_key, g: 0, parent_key: nil, priority: nil}],
      # closed: map index => node, in push order; closed_count tracks length
      closed: %{},
      closed_count: 0,
      open_seen: MapSet.new([start_key]),
      closed_index: %{},
      last_key: nil
    }

    state = gen_loop(fields, state, end_key, end_field, avoid_estate, avoid_water)

    if state.open == [] or state.last_key != end_key do
      nil
    else
      reconstruct_gen(state, start_key)
    end
  end

  defp gen_loop(fields, state, end_key, end_field, avoid_estate, avoid_water) do
    if state.last_key == end_key or state.open == [] do
      state
    else
      [node | rest] = state.open
      field = Map.fetch!(fields, node.key)

      {rest, open_seen, closed} =
        Enum.reduce(field.neighbours, {rest, state.open_seen, state.closed}, fn next,
                                                                                {o, seen, cl} ->
          cond do
            next == nil ->
              {o, seen, cl}

            next != end_key and not can_walk(fields, node.key, next, avoid_estate, avoid_water) ->
              {o, seen, cl}

            true ->
              candidate = %{
                key: next,
                parent_key: node.key,
                g: node.g + 5,
                priority: 5 + Hex.original_distance(Map.fetch!(fields, next), end_field)
              }

              case Map.get(state.closed_index, next) do
                nil ->
                  if MapSet.member?(seen, next) do
                    {o, seen, cl}
                  else
                    {o ++ [candidate], MapSet.put(seen, next), cl}
                  end

                prior ->
                  if Map.fetch!(cl, prior).g > candidate.g do
                    {o, seen, Map.put(cl, prior, candidate)}
                  else
                    {o, seen, cl}
                  end
              end
          end
        end)

      closed_index = Map.put(state.closed_index, node.key, state.closed_count)
      closed = Map.put(closed, state.closed_count, node)

      # front-swap the lowest-priority node (strict <, first index wins)
      rest =
        case rest do
          [] ->
            []

          _ ->
            {best_i, _} =
              rest
              |> Enum.with_index()
              |> Enum.reduce({0, nil}, fn {n, i}, {bi, bp} ->
                cond do
                  bp == nil -> {i, n.priority}
                  n.priority != nil and n.priority < bp -> {i, n.priority}
                  true -> {bi, bp}
                end
              end)

            first = Enum.at(rest, 0)
            chosen = Enum.at(rest, best_i)
            rest |> List.replace_at(0, chosen) |> List.replace_at(best_i, first)
        end

      state = %{
        state
        | open: rest,
          open_seen: open_seen,
          closed: closed,
          closed_count: state.closed_count + 1,
          closed_index: closed_index,
          last_key: node.key
      }

      gen_loop(fields, state, end_key, end_field, avoid_estate, avoid_water)
    end
  end

  defp reconstruct_gen(state, start_key) do
    last = Map.fetch!(state.closed, state.closed_count - 1)
    guard = state.closed_count + 1
    walk_gen(state, last, start_key, guard, [])
  end

  defp walk_gen(_state, nil, _start, _guard, acc), do: finish_gen(acc, nil)

  defp walk_gen(state, node, start_key, guard, acc) do
    if guard <= 0 do
      finish_gen(acc, start_key)
    else
      acc = [node.key | acc]

      if node.key == start_key do
        finish_gen(acc, start_key)
      else
        case node.parent_key && Map.get(state.closed_index, node.parent_key) do
          nil -> finish_gen(acc, start_key)
          idx -> walk_gen(state, Map.fetch!(state.closed, idx), start_key, guard - 1, acc)
        end
      end
    end
  end

  # JS: if (path.at(-1) !== start) return null — after reverse, first must be start
  defp finish_gen(acc, start_key) do
    case acc do
      [^start_key | _] -> acc
      _ -> nil
    end
  end
end
