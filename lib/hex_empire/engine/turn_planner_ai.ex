defmodule HexEmpire.Engine.TurnPlannerAi do
  @moduledoc """
  The challenger AI: deterministic beam search over the entire 5-move turn,
  using the pure engine as an exact forward model. (Design: docs/ai-research.md.)

  Versus the original greedy AI this fixes two structural blindspots:

    * **turn-level coordination** — the beam sequences merges, path-clearing
      and multi-wave attacks inside one turn (two big stacks crack a 99/99
      capital garrison deterministically: wave one loses but clamps the
      defender's survivors, wave two kills — the greedy scorer can neither
      execute nor anticipate this);
    * **decisive objectives** — undefended enemy home capitals are walk-in
      wins and score accordingly (the original gives them +20).

  Shape (all pure; the plan is cached in `game.ai_trace` and served one
  action at a time by `play_action/1`):

    1. once per turn: BFS distance fields from each enemy home capital and
       our own; pick a **focus target** (nearest-weakest with leader bias,
       hysteresis via deterministic recompute);
    2. candidate moves per army are pre-scored with a static scorer (focus
       gradient, oracle-checked attacks with a 1.4 power-ratio gate — waived
       against capitals, capture economics, merge value);
    3. beam of width #{8}, up to 5 levels deep, expanding the top #{12}
       candidates per state through `Engine.move` (plus an explicit "stop
       here" candidate);
    4. leaves scored by a material/income/safety evaluation of the REAL
       simulated end-of-turn state.
  """

  @behaviour HexEmpire.Engine.Ai

  alias HexEmpire.Engine
  alias HexEmpire.Engine.{Actions, Ai, Pathfinding, Query}

  @beam_width 8
  @candidates_per_state 12
  @income_horizon 8

  # ---------------------------------------------------------------------------
  # Ai behaviour: serve one action from the cached whole-turn plan
  # ---------------------------------------------------------------------------

  @impl Ai
  @spec play_action(Engine.game()) :: {Engine.game(), Engine.move_result() | nil}
  def play_action(game) do
    party = game.turn_party

    {game, plan} =
      case game.ai_trace do
        %{planner: %{key: {^party, turns}, moves: moves}}
        when turns == game.turns and moves != [] ->
          {game, moves}

        _ ->
          moves = plan_turn(game, party)
          {%{game | ai_trace: %{planner: %{key: {party, game.turns}, moves: moves}}}, moves}
      end

    case plan do
      [] ->
        {%{game | actions: 0, ai_trace: nil}, nil}

      [{from, to} | rest] ->
        # Re-verify against current legality (cheap); replan if stale.
        origin = Query.army_at(game, from)

        if origin != nil and origin.party == party and not origin.moved and
             to in Query.moves(game, from) do
          game = %{game | ai_trace: %{planner: %{key: {party, game.turns}, moves: rest}}}
          {game, result} = Actions.move_army(game, from, to)
          game = Actions.spend_action(game)
          {game, result}
        else
          play_action(%{game | ai_trace: nil})
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Whole-turn planning
  # ---------------------------------------------------------------------------

  @doc "Plan the party's whole turn: a list of `{from, to}` moves (may be < 5)."
  @spec plan_turn(Engine.game(), Engine.party()) :: [{Engine.field_key(), Engine.field_key()}]
  def plan_turn(game, party) do
    ctx = build_context(game, party)

    # Beam over sequences of moves. Each beam entry: {game, moves_reversed}.
    beam = [{game, []}]

    final =
      Enum.reduce(1..5, beam, fn _level, beam ->
        expanded =
          Enum.flat_map(beam, fn {g, moves} ->
            if g.winner != nil or g.actions <= 0 do
              [{g, moves}]
            else
              candidates(g, party, ctx)
              |> Enum.map(fn
                :stop -> {g, moves}
                {from, to} -> apply_move(g, moves, from, to)
              end)
            end
          end)

        expanded
        |> Enum.uniq_by(fn {_g, moves} -> moves end)
        |> Enum.sort_by(fn {g, _} -> -evaluate(g, party, ctx) end)
        |> Enum.take(@beam_width)
      end)

    {_g, moves} = List.first(final)
    Enum.reverse(moves)
  end

  defp apply_move(g, moves, from, to) do
    {g2, _result} = Actions.move_army(g, from, to)
    {Actions.spend_action(g2), [{from, to} | moves]}
  end

  # ---------------------------------------------------------------------------
  # Turn context: distance fields + focus target
  # ---------------------------------------------------------------------------

  defp build_context(game, party) do
    enemy_caps = Query.enemy_home_capitals(game, party)

    dist_fields =
      Map.new(enemy_caps, fn {_p, cap_key} -> {cap_key, distance_field(game, cap_key)} end)

    own_cap = Enum.at(game.capitals, party)

    focus = pick_focus(game, party, enemy_caps, dist_fields)

    %{
      enemy_caps: enemy_caps,
      dist: dist_fields,
      focus: focus,
      own_cap: own_cap,
      own_dist: own_cap && distance_field(game, own_cap)
    }
  end

  # Focus target: nearest-weakest blend with a leader bias. Deterministic per
  # turn (hysteresis emerges from the distance term barely changing).
  defp pick_focus(game, party, enemy_caps, dist_fields) do
    my_frontline = frontline_distance(game, party, dist_fields)

    scored =
      for {p, cap_key} <- enemy_caps do
        power = max(Query.total_power(game, p), 1)
        dist = Map.get(my_frontline, cap_key, 999)

        leader_bias =
          if power > 1.5 * second_best_power(game, p), do: 0.3, else: 0.0

        {100 / (dist + 5) + 120 / power + leader_bias, cap_key}
      end

    case Enum.sort_by(scored, fn {s, _} -> -s end) do
      [{_s, cap_key} | _] -> cap_key
      [] -> nil
    end
  end

  defp second_best_power(game, excluding) do
    0..3
    |> Enum.reject(&(&1 == excluding))
    |> Enum.map(&Query.total_power(game, &1))
    |> Enum.max(fn -> 1 end)
  end

  # Nearest own army's distance to each enemy capital.
  defp frontline_distance(game, party, dist_fields) do
    armies = Query.movable_armies(game, party)

    Map.new(dist_fields, fn {cap_key, field} ->
      min_dist =
        armies
        |> Enum.map(&Map.get(field, &1, 999))
        |> Enum.min(fn -> 999 end)

      {cap_key, min_dist}
    end)
  end

  # BFS distance field (in moves-ish steps) from `target` over walkable land,
  # reusing the engine's canWalk semantics in reverse (symmetric enough for
  # a gradient; sea lanes via ports are handled by can_walk itself).
  defp distance_field(game, target) do
    bfs(game, %{target => 0}, [target])
  end

  defp bfs(_game, dist, []), do: dist

  defp bfs(game, dist, frontier) do
    {dist, next} =
      Enum.reduce(frontier, {dist, []}, fn key, {d, nxt} ->
        field = Query.field(game, key)

        Enum.reduce(field.neighbours, {d, nxt}, fn n, {d2, nxt2} ->
          if n != nil and not Map.has_key?(d2, n) and
               Pathfinding.can_walk(game.fields, n, key, [], true) do
            {Map.put(d2, n, Map.fetch!(d2, key) + 1), [n | nxt2]}
          else
            {d2, nxt2}
          end
        end)
      end)

    bfs(game, dist, next)
  end

  # ---------------------------------------------------------------------------
  # Candidate generation (pre-scored, pruned)
  # ---------------------------------------------------------------------------

  defp candidates(game, party, ctx) do
    moves =
      for from <- Query.movable_armies(game, party),
          to <- Query.moves(game, from),
          score = candidate_score(game, party, ctx, from, to),
          score != nil do
        {score, {from, to}}
      end

    top =
      moves
      |> Enum.sort_by(fn {s, _} -> -s end)
      |> Enum.take(@candidates_per_state)
      |> Enum.map(fn {_s, mv} -> mv end)

    [:stop | top]
  end

  # nil prunes the candidate outright.
  defp candidate_score(game, party, ctx, from, to) do
    army = Query.army_at(game, from)
    field = Query.field(game, to)
    occupant = field.army

    cond do
      # Friendly merge: consolidate only when it builds a meaningful stack.
      occupant != nil and occupant.party == party ->
        if occupant.count < 70 and army.count < 70,
          do: 5 + (occupant.count + army.count) / 12,
          else: nil

      # Attack: oracle-gated. Ordinary fights need a 1.4 power ratio;
      # capital fights are always searchable (multi-wave plans need the
      # "losing" first wave to be a legal candidate).
      occupant != nil ->
        ap = Query.power(army)
        dp = Query.power(occupant)
        capital? = field.capital >= 0

        cond do
          capital? -> 400 + ap - dp
          ap >= 1.4 * dp -> 120 + capture_value(field) + gradient_gain(ctx, from, to)
          true -> nil
        end

      # Empty field: captures + gradient toward the focus capital.
      true ->
        walk_in =
          if field.capital >= 0 and field.party != party, do: 5000, else: 0

        walk_in + capture_value(field) + gradient_gain(ctx, from, to) +
          defense_value(game, party, ctx, to)
    end
  end

  defp capture_value(%{estate: :town}), do: 40
  defp capture_value(%{estate: :port}), do: 40
  defp capture_value(%{type: :land, party: -1}), do: 3
  defp capture_value(%{type: :land}), do: 6
  defp capture_value(_), do: 0

  defp gradient_gain(ctx, from, to) do
    case ctx.focus && ctx.dist[ctx.focus] do
      nil ->
        0

      field ->
        from_d = Map.get(field, from, 999)
        to_d = Map.get(field, to, 999)
        (from_d - to_d) * 6
    end
  end

  # Pull armies home when the capital is threatened.
  defp defense_value(game, party, ctx, to) do
    with cap when cap != nil <- ctx.own_cap,
         field when field != nil <- ctx.own_dist do
      threat = Query.enemy_power_near(game, party, cap)
      garrison = Query.friendly_power_near(game, party, cap)

      if threat > garrison do
        from_cap = Map.get(field, to, 999)
        max(0, 30 - from_cap * 6)
      else
        0
      end
    else
      _ -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Leaf evaluation (on REAL simulated states)
  # ---------------------------------------------------------------------------

  defp evaluate(game, party, ctx) do
    if game.winner == party do
      1.0e9
    else
      material(game, party, ctx) + income_term(game, party, ctx) +
        safety_term(game, party, ctx) + gradient_term(game, party, ctx) +
        hygiene_term(game, party)
    end
  end

  # Killing the focus target's army is nearly as valuable as keeping our own —
  # a flat low enemy weight makes every fair trade look bad and breeds a
  # turtle (v1 lesson, see tournament history in docs/ai-research.md).
  defp material(game, party, ctx) do
    own = Query.total_power(game, party)
    focus_party = ctx.focus && Query.field(game, ctx.focus).capital

    enemy =
      Enum.reduce(0..3, 0, fn p, acc ->
        cond do
          p == party -> acc
          p == focus_party -> acc + 0.75 * Query.total_power(game, p)
          true -> acc + 0.3 * Query.total_power(game, p)
        end
      end)

    own - enemy
  end

  defp income_term(game, party, ctx) do
    focus_party = ctx.focus && Query.field(game, ctx.focus).capital

    denial =
      if focus_party != nil and focus_party != party,
        do: 4 * Query.income(game, focus_party),
        else: 0

    @income_horizon * Query.income(game, party) - denial
  end

  defp safety_term(game, party, ctx) do
    case ctx.own_cap do
      nil ->
        0

      cap ->
        holder = Query.field(game, cap).party

        if holder != party do
          -5000
        else
          threat = Query.enemy_power_near(game, party, cap)
          garrison = Query.friendly_power_near(game, party, cap)
          -3.0 * max(0, threat - garrison)
        end
    end
  end

  defp gradient_term(game, party, ctx) do
    case ctx.focus && ctx.dist[ctx.focus] do
      nil ->
        0

      field ->
        best =
          game
          |> Query.movable_armies(party)
          |> Enum.map(&Map.get(field, &1, 999))
          |> Enum.min(fn -> 999 end)

        # Distance measured for ALL armies (moved ones included) via army scan:
        all =
          for key <- Enum.at(game.armies_by_party, party),
              pos = Map.get(game.army_pos, key),
              pos != nil,
              do: Map.get(field, pos, 999)

        nearest = Enum.min(all ++ [best], fn -> 999 end)
        average = if all == [], do: nearest, else: Enum.sum(all) / length(all)
        -10.0 * nearest - 2.0 * average
    end
  end

  # Don't let 99-stacks camp producers (income clamps away); keep armies movable.
  defp hygiene_term(game, party) do
    Enum.at(game.armies_by_party, party)
    |> Enum.reduce(0, fn id, acc ->
      case Map.get(game.army_pos, id) do
        nil ->
          acc

        key ->
          field = Query.field(game, key)
          army = field.army

          if army != nil and army.count >= 99 and field.estate != nil,
            do: acc - 5,
            else: acc
      end
    end)
  end
end
