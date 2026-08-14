defmodule HexEmpire.Engine.Movement do
  @moduledoc """
  Port of original/movement.js possibleMoves — layered BFS, exact order
  (the returned list order feeds the AI's stable sort tie-breaking).

  Rules (defaults): moveDistance 2, openWater false. The checkPower branch is
  dead (the AI passes checkPower=false at both call sites, and the LiveView UI
  never requests it).
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.Config

  @doc """
  All fields the army on `field_key` may move to, in the original push order.
  `no_self`: omit the origin from the result (both the AI and the LiveView UI
  pass true; the default false exists for parity with the JS signature).
  Returns a list of field keys.
  """
  @spec possible_moves(Engine.game(), Engine.field_key(), boolean()) :: [Engine.field_key()]
  def possible_moves(game, field_key, no_self \\ false) do
    field = Map.fetch!(game.fields, field_key)
    distance = game.rules.move_distance
    open_water = Config.has_rule?(game, :open_water)

    moves = if no_self, do: [], else: [field_key]
    seen = MapSet.new([field_key])

    bfs(game, field, [field_key], moves, seen, 1, distance, open_water)
  end

  # `moves` accumulates in reverse push order; base cases reverse once.
  defp bfs(_game, _origin, [], moves, _seen, _step, _distance, _ow), do: Enum.reverse(moves)

  defp bfs(_game, _origin, _layer, moves, _seen, step, distance, _ow) when step > distance,
    do: Enum.reverse(moves)

  defp bfs(game, origin, layer, moves, seen, step, distance, open_water) do
    {moves, seen, next} =
      Enum.reduce(layer, {moves, seen, []}, fn cur_key, acc ->
        cur = Map.fetch!(game.fields, cur_key)

        Enum.reduce(cur.neighbours, acc, fn cand_key, {mv, sn, nx} ->
          cond do
            cand_key == nil ->
              {mv, sn, nx}

            not step_allowed?(game, origin, cur, cand_key, open_water) ->
              {mv, sn, nx}

            MapSet.member?(sn, cand_key) ->
              {mv, sn, nx}

            true ->
              sn = MapSet.put(sn, cand_key)

              if join_condition?(game, cand_key, origin) do
                mv = [cand_key | mv]

                nx =
                  if step < distance and can_continue?(game, cur, cand_key),
                    do: nx ++ [cand_key],
                    else: nx

                {mv, sn, nx}
              else
                {mv, sn, nx}
              end
          end
        end)
      end)

    bfs(game, origin, next, moves, seen, step + 1, distance, open_water)
  end

  defp step_allowed?(game, origin, cur, cand_key, open_water) do
    cand = Map.fetch!(game.fields, cand_key)

    cond do
      origin.type == :water -> cur.key == origin.key or cur.type == :water
      cand.type == :land -> cur.type == :land
      true -> open_water or (cur.key == origin.key and origin.estate == :port)
    end
  end

  defp join_condition?(game, cand_key, origin) do
    cand = Map.fetch!(game.fields, cand_key)

    cond do
      cand_key == origin.key ->
        false

      cand.army == nil ->
        true

      true ->
        source_party = origin.army && origin.army.party

        cand.army.party != source_party or
          (cand.type != :water and cand.army.count < Config.max_army())
    end
  end

  defp can_continue?(game, cur, cand_key) do
    cand = Map.fetch!(game.fields, cand_key)

    cond do
      cand.army != nil -> false
      cand.type == :land and cand.estate != nil -> false
      cur.type == :water and cand.type == :land -> false
      true -> true
    end
  end
end
