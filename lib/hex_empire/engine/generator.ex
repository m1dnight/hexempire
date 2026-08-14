defmodule HexEmpire.Engine.Generator do
  @moduledoc """
  Port of original/generator.js — bit-exact map generation, including every
  cosmetic RNG draw (background tiles, water art, city art) because they all
  share the gameplay LCG.

  Field order is column-major: x outer 0..19, y inner 0..10 (index = x*11 + y).

  `generate/1` returns a map `%{fields: %{key => field}, field_order: [key],
  capitals: [key], towns: [key], ring2: %{key => [key]}, rng: seed}` where
  each field is a `%HexEmpire.Engine.Field{}` (see that module for the shape).
  `ring2` is the precomputed 2-ring topology (`Hex.further_neighbours/2` per
  field — immutable once the board exists; the AI reads it every score pass).
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.{CityNames, Config, Field, Hex, Pathfinding, Rng}

  @typedoc "The generated board (see the moduledoc for the field shape)."
  @type board :: %{
          fields: %{Engine.field_key() => Engine.field()},
          field_order: [Engine.field_key()],
          capitals: [Engine.field_key()],
          towns: [Engine.field_key()],
          ring2: %{Engine.field_key() => [Engine.field_key()]},
          rng: integer()
        }

  @doc "Generate the board from an LCG seed (see the moduledoc)."
  @spec generate(integer()) :: board()
  def generate(rng) do
    cols = Config.columns()
    rows = Config.rows()

    # createBackground(): 6x4 tiles x 5 draws (6, 6, 2, 2, 4) — cosmetic, consumes RNG.
    rng =
      Enum.reduce(1..24, rng, fn _, r ->
        {_, r} = Rng.next_int(r, 6)
        {_, r} = Rng.next_int(r, 6)
        {_, r} = Rng.next_int(r, 2)
        {_, r} = Rng.next_int(r, 2)
        {_, r} = Rng.next_int(r, 4)
        r
      end)

    # Fields, x-outer / y-inner. Corners are land without drawing.
    coords = for x <- 0..(cols - 1), y <- 0..(rows - 1), do: {x, y}

    {fields_list, rng} =
      Enum.reduce(coords, {[], rng}, fn {x, y}, {acc, r} ->
        corner? = (x == 1 or x == cols - 2) and (y == 1 or y == rows - 2)

        {type, r} =
          if corner? do
            {:land, r}
          else
            {v, r2} = Rng.next_int(r, 10)
            {if(v <= 1, do: :land, else: :water), r2}
          end

        field = %Field{
          key: Hex.field_key(x, y),
          x: x,
          y: y,
          type: type,
          party: -1,
          capital: -1,
          estate: nil,
          army: nil,
          land_id: -1,
          neighbours: [],
          town_name: ""
        }

        {[field | acc], r}
      end)

    field_order = fields_list |> Enum.reverse() |> Enum.map(& &1.key)

    fields =
      Map.new(fields_list, fn f -> {f.key, f} end)

    # linkNeighbours
    fields =
      Map.new(fields, fn {k, f} ->
        neighbours =
          for {nx, ny} <- Hex.neighbour_coordinates(f.x, f.y) do
            nk = Hex.field_key(nx, ny)
            if Map.has_key?(fields, nk), do: nk, else: nil
          end

        {k, %{f | neighbours: neighbours}}
      end)

    # Dilation pass (two-phase): every water touching land becomes land.
    to_land =
      for key <- field_order,
          f = Map.fetch!(fields, key),
          f.type == :water,
          Enum.any?(f.neighbours, fn n -> n && Map.fetch!(fields, n).type == :land end),
          do: key

    fields =
      Enum.reduce(to_land, fields, fn k, fs -> Map.update!(fs, k, &%{&1 | type: :land}) end)

    # Sequential single-tile-lake removal (mutations visible to later fields).
    fields =
      Enum.reduce(field_order, fields, fn key, fs ->
        f = Map.fetch!(fs, key)

        if f.type == :water and
             not Enum.any?(f.neighbours, fn n -> n && Map.fetch!(fs, n).type == :water end) do
          Map.put(fs, key, %{f | type: :land})
        else
          fs
        end
      end)

    # Connected components in field order (BFS with forward-scanning group).
    {fields, lands} = components(fields, field_order)

    # Corner capitals, party order 0..3.
    corners = [
      {1, 1},
      {cols - 2, 1},
      {cols - 2, rows - 2},
      {1, rows - 2}
    ]

    {fields, capitals, towns} =
      corners
      |> Enum.with_index()
      |> Enum.reduce({fields, [], []}, fn {{x, y}, party}, {fs, caps, tw} ->
        key = Hex.field_key(x, y)
        fs = Map.update!(fs, key, &%{&1 | estate: :town, capital: party})
        fs = annex_startup(fs, party, key)
        {fs, caps ++ [key], tw ++ [key]}
      end)

    # Towns per land component: floor(size/10)+1 each, <=11 attempts, 1 draw per attempt.
    {fields, towns, rng} =
      Enum.reduce(lands, {fields, towns, rng}, fn land, {fs, tw, r} ->
        count = div(length(land), 10) + 1
        land_tuple = List.to_tuple(land)
        land_len = tuple_size(land_tuple)

        Enum.reduce(1..count, {fs, tw, r}, fn _, {fs2, tw2, r2} ->
          place_town(fs2, tw2, r2, land_tuple, land_len, 0)
        end)
      end)

    # SWF shuffle of the towns list.
    {towns, rng} = Rng.shuffle(rng, towns)

    # Ports along generation paths between consecutive shuffled towns.
    {fields, _ports_created} =
      Enum.reduce(0..(length(towns) - 2)//1, {fields, 0}, fn i, {fs, ports_created} ->
        a = Enum.at(towns, i)
        b = Enum.at(towns, i + 1)

        path = Pathfinding.find_original_generation_path(fs, a, b, [:town], true)

        path =
          if path == nil or length(path) > ports_created do
            Pathfinding.find_original_generation_path(fs, a, b, [:town], false)
          else
            path
          end

        case path do
          nil ->
            {fs, ports_created}

          path ->
            path_t = List.to_tuple(path)
            n = tuple_size(path_t)

            Enum.reduce(1..(n - 2)//1, {fs, ports_created}, fn p, {fs2, pc} ->
              cur = Map.fetch!(fs2, elem(path_t, p))

              if cur.type != :land do
                {fs2, pc}
              else
                nxt = Map.fetch!(fs2, elem(path_t, p + 1))
                prv = Map.fetch!(fs2, elem(path_t, p - 1))

                # Two independent checks — double increment preserved.
                {fs2, pc} =
                  if nxt.type == :water,
                    do: {Map.update!(fs2, cur.key, &%{&1 | estate: :port}), pc + 1},
                    else: {fs2, pc}

                if prv.type == :water,
                  do: {Map.update!(fs2, cur.key, &%{&1 | estate: :port}), pc + 1},
                  else: {fs2, pc}
              end
            end)
        end
      end)

    # Water art: 4 draws per water tile in field order (cosmetic).
    rng =
      Enum.reduce(field_order, rng, fn key, r ->
        if Map.fetch!(fields, key).type == :water do
          {_, r} = Rng.next_int(r, 6)
          {_, r} = Rng.next_int(r, 2)
          {_, r} = Rng.next_int(r, 2)
          {_, r} = Rng.next_int(r, 2)
          r
        else
          r
        end
      end)

    # City art (5 draws) + name draw per town/port, with the original's
    # names[n] = names[0]; names.shift() removal pattern.
    {fields, rng, _names} =
      Enum.reduce(field_order, {fields, rng, CityNames.all()}, fn key, {fs, r, names} ->
        f = Map.fetch!(fs, key)

        if f.estate in [:town, :port] do
          {_, r} = Rng.next_int(r, 6)
          {_, r} = Rng.next_int(r, 6)
          {_, r} = Rng.next_int(r, 2)
          {_, r} = Rng.next_int(r, 2)
          {_, r} = Rng.next_int(r, 360)
          {n, r} = Rng.next_int(r, length(names))
          name = Enum.at(names, n) || "City #{f.x}-#{f.y}"
          names = names |> List.replace_at(n, hd(names)) |> tl()
          {Map.put(fs, key, %{f | town_name: name}), r, names}
        else
          {fs, r, names}
        end
      end)

    # Precomputed 2-ring topology for the AI's neighbourhood scans. Built with
    # the SAME Hex.further_neighbours/2 the engine would otherwise call per
    # lookup, so the list order is identical by construction (load-bearing:
    # the AI folds these lists in order). Topology (field.neighbours) never
    # changes after linkNeighbours, so this is safe to compute once here.
    ring2 = Map.new(field_order, fn key -> {key, Hex.further_neighbours(fields, key)} end)

    %{
      fields: fields,
      field_order: field_order,
      capitals: capitals,
      towns: towns,
      ring2: ring2,
      rng: rng
    }
  end

  # annexStartup: field.party = party; land neighbours without estate/army join.
  defp annex_startup(fields, party, key) do
    fields = Map.update!(fields, key, &%{&1 | party: party})
    f = Map.fetch!(fields, key)

    Enum.reduce(f.neighbours, fields, fn n, fs ->
      case n && Map.fetch!(fs, n) do
        %{type: :land, estate: nil, army: nil} = nf -> Map.put(fs, n, %{nf | party: party})
        _ -> fs
      end
    end)
  end

  # One town placement: while(!made && attempts++ <= 10) — up to 11 attempts, 1 draw each.
  defp place_town(fields, towns, rng, _land, _len, attempts) when attempts > 10,
    do: {fields, towns, rng}

  defp place_town(fields, towns, rng, land, len, attempts) do
    {idx, rng} = Rng.next_int(rng, len)
    key = elem(land, idx)
    f = Map.fetch!(fields, key)

    ok? =
      f.estate == nil and
        Enum.all?(f.neighbours, fn n ->
          n == nil or
            (
              nf = Map.fetch!(fields, n)
              nf.type != :water and nf.estate == nil
            )
        end)

    if ok? do
      {Map.update!(fields, key, &%{&1 | estate: :town}), towns ++ [key], rng}
    else
      place_town(fields, towns, rng, land, len, attempts + 1)
    end
  end

  # components(): field order scan; BFS growing a group list scanned forward.
  defp components(fields, field_order) do
    Enum.reduce(field_order, {fields, []}, fn key, {fs, lands} ->
      f = Map.fetch!(fs, key)

      if f.type != :land or f.land_id >= 0 do
        {fs, lands}
      else
        land_id = length(lands)
        fs = Map.put(fs, key, %{f | land_id: land_id})
        {fs, group} = bfs_component(fs, [key], 0, land_id)
        {fs, lands ++ [group]}
      end
    end)
  end

  defp bfs_component(fields, group, i, land_id) do
    if i >= length(group) do
      {fields, group}
    else
      key = Enum.at(group, i)
      f = Map.fetch!(fields, key)

      {fields, group} =
        Enum.reduce(f.neighbours, {fields, group}, fn n, {fs, g} ->
          case n && Map.fetch!(fs, n) do
            %{type: :land, land_id: -1} = nf ->
              {Map.put(fs, n, %{nf | land_id: land_id}), g ++ [n]}

            _ ->
              {fs, g}
          end
        end)

      bfs_component(fields, group, i + 1, land_id)
    end
  end
end
