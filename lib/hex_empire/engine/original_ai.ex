defmodule HexEmpire.Engine.OriginalAi do
  @moduledoc """
  Port of original/originalAi.js — standard game mode (no flags on generated
  maps, so the CTF/domination branches are dead; objectiveScore is 0).

  Faithfulness notes:

  * `field.waitForSupport` is written by EVERY scoreMove evaluation
    (last-writer-wins across the whole ranking pass, armies in board order,
    candidate fields in possibleMoves BFS order). The caller accumulates each
    evaluation's returned flag into a `wait_flags` map (last writer wins) and
    only the chosen target's final flag is ever read — identical observable
    behavior to the JS unconditional field-flag overwrite.
  * All sorts are stable (Elixir's merge sort), matching JS Array#sort in
    modern engines. Tie-breaks: choices by key (lexicographic — equals
    localeCompare for these ASCII keys), ranked/supporter by power desc,
    residual ties keep iteration order.
  """

  @behaviour HexEmpire.Engine.Ai

  alias HexEmpire.Engine
  alias HexEmpire.Engine.{Actions, Ai, Query}

  # ---------------------------------------------------------------------------
  # Public: one AI action / a full fast AI turn
  # ---------------------------------------------------------------------------

  @doc """
  performAiAction: one AI move for the current turn party — rank every
  movable army's best target, apply the wait-for-support bookkeeping (and the
  supporter substitution when the top choice waits), then move and spend an
  action. Returns `{game, result | nil}`; nil means no move was possible and
  the action budget was zeroed.
  """
  @impl Ai
  @spec play_action(Engine.game()) :: {Engine.game(), Engine.move_result() | nil}
  def play_action(game), do: perform_ai_action(game)

  @spec perform_ai_action(Engine.game()) :: {Engine.game(), Engine.move_result() | nil}
  def perform_ai_action(game) do
    party = game.turn_party
    {ranked, wait_flags} = rank_ai_armies(game, party)

    case ranked do
      [] ->
        {%{game | actions: 0}, nil}

      [choice | _] ->
        {game, choice} =
          if Map.get(wait_flags, choice.target, false) do
            game =
              if Enum.at(game.wait_support_field, party) == choice.target do
                %{
                  game
                  | wait_support_count: List.update_at(game.wait_support_count, party, &(&1 + 1))
                }
              else
                %{
                  game
                  | wait_support_field:
                      List.replace_at(game.wait_support_field, party, choice.target),
                    wait_support_count: List.replace_at(game.wait_support_count, party, 0)
                }
              end

            {game, supporter(game, party, choice.army, choice.target) || choice}
          else
            game = %{
              game
              | wait_support_field: List.replace_at(game.wait_support_field, party, nil),
                wait_support_count: List.replace_at(game.wait_support_count, party, 0)
            }

            {game, choice}
          end

        game = %{
          game
          | ai_trace: %{party: party, from: choice.army, to: choice.target, score: choice.score}
        }

        {game, result} = Actions.move_army(game, choice.army, choice.target)
        game = Actions.spend_action(game)
        {game, result}
    end
  end

  @doc """
  performFastAiTurn: play the current party's whole turn, re-ranking after
  every move (the shared `Ai.play_turn/2` driver preserves the exact original
  loop). Does not finish the turn.
  """
  @spec perform_fast_ai_turn(Engine.game()) :: Engine.game()
  def perform_fast_ai_turn(game), do: Ai.play_turn(game, __MODULE__)

  # ---------------------------------------------------------------------------
  # Ranking
  # ---------------------------------------------------------------------------

  @doc "Returns `{ranked, wait_flags}`; ranked entries: %{army: key, target: key, score: n}."
  @spec rank_ai_armies(Engine.game(), Engine.party()) ::
          {[map()], %{Engine.field_key() => boolean()}}
  def rank_ai_armies(game, party) do
    armies = Query.movable_armies(game, party)

    # `grads` memoizes capital_gradient per {field, capital} for THIS ranking
    # pass only — fields are frozen while ranking, so find_path is pure here.
    {ranked, wait_flags, _grads} =
      Enum.reduce(armies, {[], %{}, %{}}, fn army_key, {ranked, wait_flags, grads} ->
        origin = Query.field(game, army_key)
        army = origin.army

        {choices, wait_flags, grads} =
          game
          |> Query.moves(army_key)
          |> Enum.reduce({[], wait_flags, grads}, fn field_key, {cs, wf, gr} ->
            {score, flag, gr} = score_move_cached(game, party, army_key, field_key, gr)
            {[%{field: field_key, score: score} | cs], Map.put(wf, field_key, flag), gr}
          end)

        choices =
          choices
          |> Enum.reverse()
          |> Enum.sort_by(fn c -> {-c.score, c.field} end)

        case choices do
          [] ->
            {ranked, wait_flags, grads}

          [best | _] ->
            score = best.score

            score =
              if origin.capital == party and game.turns > 5,
                do: score - 1000,
                else: score

            {ranked ++
               [
                 %{army: army_key, target: best.field, score: score, power: Query.power(army)}
               ], wait_flags, grads}
        end
      end)

    ranked =
      Enum.sort_by(ranked, fn r -> {-r.score, -r.power} end)

    {ranked, wait_flags}
  end

  # ---------------------------------------------------------------------------
  # Scoring — exact port of scoreMove
  # ---------------------------------------------------------------------------

  @doc "Returns `{score, wait_for_support_flag}` for moving `army` to `field_key`."
  @spec score_move(Engine.game(), Engine.party(), Engine.field_key(), Engine.field_key()) ::
          {number(), boolean()}
  def score_move(game, party, army_key, field_key) do
    {score, flag, _grads} = score_move_cached(game, party, army_key, field_key, %{})
    {score, flag}
  end

  # score_move threading the per-ranking-pass capital_gradient memo (see
  # rank_ai_armies); returns {score, wait_for_support_flag, grads}.
  defp score_move_cached(game, party, army_key, field_key, grads) do
    origin = Query.field(game, army_key)
    army = origin.army
    field = Query.field(game, field_key)

    # (a) march gradient: closest enemy home capital dominates the base score
    # (walking-path length toward each enemy-held original capital, negated;
    # the human's capital gets +difficulty*2 so harder AIs hunt the player)
    {score, grads} =
      Enum.reduce(Query.enemy_home_capitals(game, party), {-1.0e7, grads}, fn {p, cap_key},
                                                                              {acc, gr} ->
        {s, gr} = capital_gradient(gr, game, field_key, cap_key)
        s = if p == game.human, do: s + game.difficulty * 2, else: s
        {max(acc, s), gr}
      end)

    # (c) enemy-land bonuses; guaranteed capital kill
    {score, guaranteed} =
      if field.type == :land and field.party != party do
        cond do
          field.capital >= 0 and field.capital == field.party and field.army != nil and
              Query.power(army) > Query.power(field.army) ->
            {score + 1.0e6, true}

          field.capital >= 0 ->
            {score + 20, false}

          field.estate == :town ->
            {score + 5, false}

          field.estate == :port ->
            {score + 3, false}

          Query.near?(game, field_key, fn n -> n.estate == :town end) ->
            {score + 3, false}

          true ->
            {score, false}
        end
      else
        {score, false}
      end

    # (d) enemy army on the field
    score =
      if field.army != nil and field.army.party != party do
        score =
          if Query.near?(game, field_key, fn n -> n.capital == party end),
            do: score + 1000,
            else: score

        score =
          if field.army.party != game.human and
               Query.total_power(game, field.army.party) > 1.5 * Query.total_power(game, party) and
               Query.power(field.army) > Query.power(army) and
               ((field.army.party < 2 and party < 2) or (field.army.party > 1 and party > 1)),
             do: score + 200,
             else: score

        if game.difficulty > 5 and field.army.party != game.human,
          do: score - 250,
          else: score
      else
        score
      end

    # (e) merge-into-bigger-stack nudge
    score =
      if field.army != nil and field.army.party == party and field.army.count > army.count and
           field.army.count < 70,
         do: score + 2,
         else: score

    # (f) early own-capital exodus
    score =
      if origin.capital == party and field.army == nil and game.turns < 5,
        do: score + 50,
        else: score

    # (g) objectiveScore — standard mode with no flags: 0

    # (h) wait-for-support
    friendly_power = Query.friendly_power_near(game, party, field_key)
    enemy_power = Query.enemy_power_near(game, party, field_key)
    defender_power = Query.power(field.army)

    wait_condition =
      ((friendly_power < enemy_power and friendly_power < 300) or
         (Query.power(army) < defender_power and army.count < 90)) and
        not Query.near?(game, field_key, fn n -> n.capital == party end) and
        not guaranteed

    if wait_condition do
      if Enum.at(game.wait_support_field, party) == field_key and
           Enum.at(game.wait_support_count, party) >= 5 do
        {score - 5, false, grads}
      else
        {score, true, grads}
      end
    else
      {score, false, grads}
    end
  end

  # ---------------------------------------------------------------------------
  # Supporter
  # ---------------------------------------------------------------------------

  @doc """
  Pick the friendly army (not the primary, not on the party's capital) whose
  best reachable non-target, non-enemy field is nearest (originalDistance) to
  the wait-support target; nil when none qualifies.
  """
  @spec supporter(Engine.game(), Engine.party(), Engine.field_key(), Engine.field_key()) ::
          map() | nil
  def supporter(game, party, primary_key, target_key) do
    candidates =
      game
      |> Query.movable_armies(party)
      |> Enum.reduce([], fn army_key, acc ->
        origin = Query.field(game, army_key)

        if army_key != primary_key and origin.capital != party do
          moves =
            game
            |> Query.moves(army_key)
            |> Enum.filter(fn f ->
              occupant = Query.army_at(game, f)
              f != target_key and (occupant == nil or occupant.party == party)
            end)

          case moves do
            [] ->
              acc

            _ ->
              [best | _] = Enum.sort_by(moves, fn f -> Query.distance(game, f, target_key) end)

              acc ++
                [
                  %{
                    army: army_key,
                    target: best,
                    score: -Query.distance(game, best, target_key),
                    power: Query.power(origin.army)
                  }
                ]
          end
        else
          acc
        end
      end)

    candidates
    |> Enum.sort_by(fn c -> {-c.score, -c.power} end)
    |> List.first()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Memoized per ranking pass (see rank_ai_armies): find_path reads only the
  # fields' type/estate/x/y, all frozen while a pass ranks, so the cached
  # value is exactly what a fresh find_path would return.
  defp capital_gradient(cache, game, field_key, capital_key) do
    cache_key = {field_key, capital_key}

    case cache do
      %{^cache_key => s} ->
        {s, cache}

      _ ->
        s =
          case Query.path(game, field_key, capital_key) do
            nil -> -999
            path -> -length(path)
          end

        {s, Map.put(cache, cache_key, s)}
    end
  end
end
