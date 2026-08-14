defmodule HexEmpire.Engine.State do
  @moduledoc """
  Port of original/state.js — game creation, derived state, and the turn
  machinery. Flags/domination/CTF are not ported (generated maps carry no
  flags; standard mode only). Cheats/fog are display-only or absent.

  The game is a `%HexEmpire.Engine.Game{}` struct; armies live embedded in
  fields (field.army), and the derived per-party army lists
  (`armies_by_party`, keys in board order) mirror the original's listArmies
  arrays.
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.{Army, Config, Game, Generator, Morale, Reinforcements, Rng}

  # ---------------------------------------------------------------------------
  # Creation
  # ---------------------------------------------------------------------------

  @doc """
  createGame: generate the board from `:seed` (required) and set up the four
  parties. Options: `:human` (default 0), `:difficulty` (default
  `Config.default_difficulty/0`), `:rules` (merged over the defaults), and
  `:spectating` (default false — `human: -1, spectating: true` is the
  original's spectator mode, which multiplayer matches run under: no
  human-biased AI branches, round counter ticks on wrap, victory goes to the
  sole controller of all original capitals).
  Spawns each party's initial reinforcements in party order, then begins
  party 0's turn.
  """
  @spec create_game(keyword()) :: Engine.game()
  def create_game(opts \\ []) do
    seed = Keyword.fetch!(opts, :seed)
    human = Keyword.get(opts, :human, 0)
    difficulty = Keyword.get(opts, :difficulty, Config.default_difficulty())
    spectating = Keyword.get(opts, :spectating, false)
    rules = Map.merge(Config.default_rules(), Keyword.get(opts, :rules, %{}))

    rng = Rng.set_seed(seed)
    board = Generator.generate(rng)

    game = %Game{
      seed: seed,
      rng: board.rng,
      fields: board.fields,
      field_order: board.field_order,
      capitals: board.capitals,
      ring2: board.ring2,
      screen: :game,
      human: human,
      difficulty: difficulty,
      rules: rules,
      # mirrors the original's game.gameMode (only standard mode is ported)
      game_mode: :standard,
      spectating: spectating,
      status: [1, 1, 1, 1],
      morale: List.duplicate(Config.starting_morale(), 4),
      # derived (rebuilt by update_derived)
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
      # mirrors the original's totalHumanMoves counter (fed news/objectives)
      total_human_moves: 0,
      # mirrors the original's per-party speechGiven flags (speeches unported)
      speech_given: [false, false, false, false],
      winner: nil,
      victory_reason: nil,
      # mirrors the original's game.message banner (the LiveView renders its own)
      message: "",
      log: [],
      next_army_id: 1,
      # AI cross-turn state
      wait_support_field: [nil, nil, nil, nil],
      wait_support_count: [0, 0, 0, 0],
      original_capitals_remaining: 4,
      # mirrors the original's game.aiTrace (debug: last AI decision)
      ai_trace: nil
    }

    game = update_derived(game)

    game =
      Enum.reduce(0..3, game, fn p, g ->
        g |> Reinforcements.spawn_units(p) |> update_derived()
      end)

    begin_turn(game, 0)
  end

  # ---------------------------------------------------------------------------
  # Derived state — exact step order of the original updateDerived
  # ---------------------------------------------------------------------------

  @doc """
  updateDerived: rebuild every derived list/total in the original's exact
  step order — army lists, per-party status, province capitals,
  defeated-territory inheritance, towns/ports/lands, faction morale, and the
  human-condition advice indicator.
  """
  @spec update_derived(Engine.game()) :: Engine.game()
  def update_derived(game) do
    game = list_armies(game)

    # status: 1 for parties that own an original capital slot, else 0
    active = active_parties(game)
    status = for p <- 0..3, do: if(p in active, do: 1, else: 0)

    # provinceCapitals: capitals currently held by p whose original faction is armyless
    {status, province_capitals} =
      Enum.reduce(0..3, {status, [[], [], [], []]}, fn p, {st, pc} ->
        case Enum.at(game.capitals, p) do
          nil ->
            {st, pc}

          cap_key ->
            cap = Map.fetch!(game.fields, cap_key)

            captured =
              for ck <- game.capitals,
                  ck != nil,
                  c = Map.fetch!(game.fields, ck),
                  c.party == p,
                  c.capital != p,
                  Enum.at(game.armies_by_party, c.capital) == [],
                  do: ck

            cond do
              cap.party != p ->
                {List.replace_at(st, p, 0), pc}

              captured != [] ->
                {List.replace_at(st, p, 1 + length(captured)), List.replace_at(pc, p, captured)}

              true ->
                {st, pc}
            end
        end
      end)

    game = %{game | status: status, province_capitals: province_capitals}

    # Defeated territory follows the owner of the defeated faction's capital.
    game =
      Enum.reduce(game.field_order, game, fn key, g ->
        f = Map.fetch!(g.fields, key)
        occupant = if f.army, do: f.army.party, else: f.party

        if occupant >= 0 and Enum.at(g.status, occupant) == 0 do
          heir =
            case Enum.at(g.capitals, occupant) do
              nil -> -1
              ck -> Map.fetch!(g.fields, ck).party
            end

          new_party = if heir >= 0 and Enum.at(g.status, heir) != 0, do: heir, else: -1
          f = %{f | party: new_party, army: nil}
          %{g | fields: Map.put(g.fields, key, f)}
        else
          g
        end
      end)

    game = list_armies(game)

    # towns/ports/lands per party, in board order
    {towns, ports, lands} =
      Enum.reduce(
        game.field_order,
        {[[], [], [], []], [[], [], [], []], [[], [], [], []]},
        fn key, {tw, po, la} ->
          f = Map.fetch!(game.fields, key)

          cond do
            f.party < 0 -> {tw, po, la}
            f.estate == :town -> {List.update_at(tw, f.party, &(&1 ++ [key])), po, la}
            f.estate == :port -> {tw, List.update_at(po, f.party, &(&1 ++ [key])), la}
            true -> {tw, po, List.update_at(la, f.party, &(&1 ++ [key]))}
          end
        end
      )

    game = %{game | towns_by_party: towns, ports_by_party: ports, lands_by_party: lands}

    game = Morale.refresh_faction(game)

    # humanCondition (the advisor mood indicator, shown in the sidebar:
    # 0 great / 1 fine / 2 worried / 3 desperate)
    if game.human < 0 do
      %{game | human_condition: 1}
    else
      human_power = Enum.at(game.morale, game.human) + Enum.at(game.total_count, game.human)

      condition =
        Enum.reduce(0..3, 1, fn p, cond_acc ->
          if p != game.human and Enum.at(game.status, p) != 0 do
            power = Enum.at(game.morale, p) + Enum.at(game.total_count, p)

            cond do
              human_power < 0.3 * power ->
                3

              cond_acc < 3 and human_power < 0.6 * power ->
                2

              length(Enum.at(game.province_capitals, game.human)) >= 2 and human_power > 2 * power ->
                0

              true ->
                cond_acc
            end
          else
            cond_acc
          end
        end)

      %{game | human_condition: condition}
    end
  end

  @doc """
  listArmies: rebuild per-party army ID lists (board order) + totals + the
  id => field position index. The ID lists are the "stale lists" that morale
  events iterate between derived-state refreshes (original object-reference
  semantics).
  """
  @spec list_armies(Engine.game()) :: Engine.game()
  def list_armies(game) do
    {abp, tc, tp, pos} =
      Enum.reduce(game.field_order, {[[], [], [], []], [0, 0, 0, 0], [0, 0, 0, 0], %{}}, fn key,
                                                                                            {abp,
                                                                                             tc,
                                                                                             tp,
                                                                                             pos} ->
        case Map.fetch!(game.fields, key).army do
          nil ->
            {abp, tc, tp, pos}

          army ->
            {List.update_at(abp, army.party, &(&1 ++ [army.id])),
             List.update_at(tc, army.party, &(&1 + army.count)),
             List.update_at(tp, army.party, &(&1 + army.count + army.morale)),
             Map.put(pos, army.id, key)}
        end
      end)

    %{game | armies_by_party: abp, total_count: tc, total_power: tp, army_pos: pos}
  end

  @doc "Parties whose original capital slot still exists (`capitals[p] != nil`)."
  @spec active_parties(Engine.game()) :: [Engine.party()]
  def active_parties(game) do
    for p <- 0..3, Enum.at(game.capitals, p) != nil, do: p
  end

  @doc "capitalControllerWinner: sole controller of all original capitals, else nil."
  @spec capital_controller_winner(Engine.game()) :: Engine.party() | nil
  def capital_controller_winner(game) do
    controllers =
      game.capitals
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Map.fetch!(game.fields, &1).party)
      |> Enum.filter(&(&1 >= 0))
      |> Enum.uniq()

    case controllers do
      [only] -> only
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Turn machinery
  # ---------------------------------------------------------------------------

  @doc "Field keys of the party's unmoved armies (derived id list, board order)."
  @spec movable_armies(Engine.game(), Engine.party() | nil) :: [Engine.field_key()]
  def movable_armies(game, party \\ nil) do
    party = party || game.turn_party

    # The bare `key = ...` / `army = ...` bindings double as truthiness filters
    # (a nil binding drops the element from the comprehension), so no explicit
    # nil checks are needed. The `army.id == id` guard skips fields whose army
    # was replaced since armies_by_party was derived (stale-list semantics).
    for id <- Enum.at(game.armies_by_party, party),
        key = Map.get(game.army_pos, id),
        army = Map.fetch!(game.fields, key).army,
        army.id == id and not army.moved,
        do: key
  end

  @doc """
  beginTurn: set the turn party, refresh derived state, cap the action budget
  at the movable-army count, and count a human turn when `party` is the human.
  """
  @spec begin_turn(Engine.game(), Engine.party()) :: Engine.game()
  def begin_turn(game, party) do
    game = %{game | turn_party: party} |> update_derived()

    actions = min(game.rules.moves_per_turn, length(movable_armies(game, party)))

    game = %{game | turn_moves_spent: 0, actions: actions}

    game =
      if party == game.human do
        %{game | turns: game.turns + 1}
      else
        game
      end

    %{game | message: "#{Config.faction_name(party)}'s turn"}
  end

  @doc "cleanupTurn: moved flag reset; unmoved armies lose 1 morale."
  @spec cleanup_turn(Engine.game()) :: Engine.game()
  def cleanup_turn(game) do
    Enum.reduce(Enum.at(game.armies_by_party, game.turn_party), game, fn id, g ->
      case Map.get(g.army_pos, id) do
        nil ->
          g

        key ->
          a = Map.fetch!(g.fields, key).army

          a =
            if a.moved,
              do: %{a | moved: false},
              else: %{a | morale: max(0, a.morale - 1)}

          Army.put_army(g, key, a)
      end
    end)
  end

  @doc """
  Next party after `from` (wrapping) that still has armies; `from` itself
  when no party does.
  """
  @spec next_living_party(Engine.game(), Engine.party()) :: Engine.party()
  def next_living_party(game, from) do
    Enum.reduce_while(1..4, from, fn i, _ ->
      p = rem(from + i, 4)

      if Enum.at(game.armies_by_party, p) != [] do
        {:halt, p}
      else
        {:cont, from}
      end
    end)
  end

  @doc """
  finishTurn: cleanup the finished party's armies, refresh derived state,
  spawn its reinforcements, then begin the next living party's turn.
  """
  @spec finish_turn(Engine.game()) :: Engine.game()
  def finish_turn(game) do
    previous = game.turn_party

    game =
      game
      |> cleanup_turn()
      |> update_derived()
      |> Reinforcements.spawn_units(previous)
      |> update_derived()

    next = next_living_party(game, previous)

    game =
      if game.spectating and next <= previous,
        do: %{game | turns: game.turns + 1},
        else: game

    begin_turn(game, next)
  end

  @doc "setGameWinner: first winner sticks."
  @spec set_game_winner(Engine.game(), integer(), String.t()) :: Engine.game()
  def set_game_winner(game, party, reason) do
    if party < 0 or game.winner != nil do
      game
    else
      screen =
        cond do
          game.spectating or game.human < 0 -> :spectator_victory
          party == game.human -> :victory
          true -> :defeat
        end

      %{game | winner: party, victory_reason: reason, screen: screen}
      |> log("#{Config.faction_name(party)} wins (#{reason})!")
    end
  end

  @doc "Prepend a war-report line (capped at 14 entries)."
  @spec log(Engine.game(), String.t()) :: Engine.game()
  def log(game, msg), do: %{game | log: Enum.take([msg | game.log], 14)}
end
