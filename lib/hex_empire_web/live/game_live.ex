defmodule HexEmpireWeb.GameLive do
  @moduledoc """
  LiveView front-end over the faithful engine port.

  All game logic runs server-side in the ported engine, reached only through
  `HexEmpire.Campaigns` (session mutations + persistence) and the
  `HexEmpire.Engine` facade (pure queries). This module owns socket assigns,
  the AI step timer, event handling, and rendering.

  Human-play conventions (the original's UI controller was not part of the
  source drop):
    * valid moves = Engine.possible_moves (no power filter — classic behavior)
    * the turn auto-finishes when the action budget hits 0
    * speech/pacts are omitted (their effect sizes are unrecoverable)
  """

  use HexEmpireWeb, :live_view

  import HexEmpireWeb.BoardComponents, only: [board: 1, build_hexes: 4, faction: 1]

  alias HexEmpire.{Campaigns, Engine}

  # AI step cadence in ms (test config sets 1 so suites don't wait out timers)
  @ai_delay Application.compile_env(:hex_empire, :ai_delay, 220)

  @impl true
  def mount(_params, session, socket) do
    player_id = session["player_id"]
    socket = assign(socket, player_id: player_id)

    case Campaigns.resume(player_id) do
      %{game: game, difficulty: difficulty} ->
        # Resume works on both the static and the connected mount so the
        # page renders the same board twice (no flash). The AI timer is only
        # scheduled once connected — the static process dies after rendering.
        socket =
          socket
          |> assign(
            game: game,
            difficulty: difficulty,
            selected: nil,
            valid_moves: [],
            status_msg: resume_status(game)
          )
          |> assign_board()

        socket = if connected?(socket), do: maybe_schedule_ai(socket), else: socket
        {:ok, socket}

      nil ->
        # Only the connected mount creates (and persists) a new campaign;
        # the static pass renders a cheap placeholder instead of burning a
        # full map generation + save on a process about to die.
        if connected?(socket) do
          {:ok, new_game(socket, 0, 5)}
        else
          {:ok, assign(socket, game: nil)}
        end
    end
  end

  defp resume_status(g) do
    cond do
      g.winner != nil -> winner_text(g)
      g.turn_party == g.human -> "Welcome back, commander. Your move."
      true -> "#{Engine.faction_name(g.turn_party)} is moving…"
    end
  end

  defp new_game(socket, human, difficulty) do
    campaign = Campaigns.new_campaign(socket.assigns.player_id, human, difficulty)

    socket
    |> assign(
      game: campaign.game,
      difficulty: campaign.difficulty,
      selected: nil,
      valid_moves: [],
      status_msg: "Your move, commander."
    )
    |> assign_board()
    |> maybe_schedule_ai()
  end

  # The campaign map Campaigns mutators take (they persist it themselves).
  defp campaign(socket) do
    %{
      player_id: socket.assigns.player_id,
      game: socket.assigns.game,
      difficulty: socket.assigns.difficulty
    }
  end

  # =========================================================================
  # Events
  # =========================================================================

  @impl true
  def handle_event("hex", %{"k" => key}, socket) do
    g = socket.assigns.game

    if human_turn?(g) do
      {:noreply, click(socket, g, key)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("end_turn", _params, socket) do
    g = socket.assigns.game

    if human_turn?(g) do
      %{game: g} = Campaigns.end_turn(campaign(socket))

      {:noreply,
       socket
       |> assign(game: g, selected: nil, valid_moves: [])
       |> assign_board()
       |> maybe_schedule_ai()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_game", params, socket) do
    human = String.to_integer(params["faction"] || "0")
    difficulty = String.to_integer(params["difficulty"] || "5")
    {:noreply, new_game(socket, human, difficulty)}
  end

  def handle_event("create_match", _params, socket) do
    id = HexEmpire.Matches.create()
    {:noreply, push_navigate(socket, to: ~p"/m/#{id}")}
  end

  # =========================================================================
  # AI turn stepping
  # =========================================================================

  @impl true
  def handle_info(:ai_step, socket) do
    g = socket.assigns.game

    cond do
      g.winner != nil ->
        {:noreply, socket |> assign(status_msg: winner_text(g)) |> assign_board()}

      g.turn_party == g.human ->
        {:noreply, socket |> assign(status_msg: "Your move, commander.") |> assign_board()}

      true ->
        %{game: g} = Campaigns.ai_step(campaign(socket))
        socket = socket |> assign(game: g) |> assign_board()

        if g.winner == nil and g.turn_party != g.human do
          Process.send_after(self(), :ai_step, @ai_delay)

          {:noreply,
           assign(socket, status_msg: "#{Engine.faction_name(g.turn_party)} is moving…")}
        else
          msg = if g.winner, do: winner_text(g), else: "Your move, commander."
          {:noreply, assign(socket, status_msg: msg)}
        end
    end
  end

  defp maybe_schedule_ai(socket) do
    g = socket.assigns.game

    if g.winner == nil and g.turn_party != g.human do
      Process.send_after(self(), :ai_step, @ai_delay)
      assign(socket, status_msg: "#{Engine.faction_name(g.turn_party)} is moving…")
    else
      socket
    end
  end

  # =========================================================================
  # Click handling
  # =========================================================================

  defp click(socket, g, key) do
    field = Map.fetch!(g.fields, key)
    sel = socket.assigns.selected

    cond do
      # move to a highlighted field
      sel != nil and key in socket.assigns.valid_moves ->
        {%{game: g}, _moved?} = Campaigns.human_move(campaign(socket), sel, key)

        socket
        |> assign(game: g, selected: nil, valid_moves: [])
        |> assign(status_msg: if(g.winner, do: winner_text(g), else: status_after_move(g)))
        |> assign_board()
        |> maybe_schedule_ai()

      # select an own, unmoved army
      field.army != nil and field.army.party == g.human and not field.army.moved and
          g.actions > 0 ->
        moves = Engine.possible_moves(g, key, true)

        socket
        |> assign(selected: key, valid_moves: moves)
        |> assign(
          status_msg: "Army #{field.army.count}/#{field.army.morale} — choose a destination."
        )
        |> assign_board()

      true ->
        socket |> assign(selected: nil, valid_moves: []) |> assign_board()
    end
  end

  defp status_after_move(g) do
    if g.turn_party == g.human,
      do: "#{g.actions} move#{if g.actions == 1, do: "", else: "s"} left.",
      else: "#{Engine.faction_name(g.turn_party)} is moving…"
  end

  defp human_turn?(g), do: g.winner == nil and g.turn_party == g.human

  defp winner_text(g) do
    reason = if g.victory_reason, do: " (#{g.victory_reason})", else: ""

    if g.winner == g.human,
      do: "🏆 Victory! #{Engine.faction_name(g.winner)} rules the world#{reason}.",
      else: "💀 Defeat — #{Engine.faction_name(g.winner)} has won#{reason}."
  end

  # The original's advisor mood indicator (game.human_condition, computed by
  # the engine's updateDerived): 0 great / 1 fine / 2 worried / 3 desperate.
  defp advisor(0), do: "😄 Advisor: our position is excellent."
  defp advisor(1), do: "🙂 Advisor: we are holding steady."
  defp advisor(2), do: "😟 Advisor: the enemy is gaining ground."
  defp advisor(3), do: "😱 Advisor: our situation is desperate!"

  # =========================================================================
  # Board precomputation (shared renderer in HexEmpireWeb.BoardComponents)
  # =========================================================================

  defp assign_board(socket) do
    %{game: g, selected: sel, valid_moves: valid} = socket.assigns
    assign(socket, hexes: build_hexes(g, sel, valid, g.human))
  end

  # =========================================================================
  # View helpers
  # =========================================================================

  defp status_name(g, party) do
    s = Enum.at(g.status, party)
    if s == 0, do: "Defeated", else: Enum.at(Engine.status_names(), min(s, 4))
  end

  # =========================================================================
  # Render
  # =========================================================================

  # Static-mount placeholder for a brand-new player: the connected mount
  # creates the real campaign (see mount/3), so this renders exactly once.
  @impl true
  def render(%{game: nil} = assigns) do
    ~H"""
    <div style="display:flex;align-items:center;justify-content:center;height:100vh;
                background:#1d2a1c;color:#eef2e6;font-family:ui-sans-serif,system-ui,sans-serif">
      <div style="font-size:19px;font-weight:800;letter-spacing:.5px">
        HEX EMPIRE — preparing your campaign…
      </div>
    </div>
    """
  end

  # The .he-* styles (incl. the max-width:900px mobile layout) live in
  # assets/css/app.css under "Hex Empire game UI".
  def render(assigns) do
    ~H"""
    <div class="he-root">
      <div class="he-board">
        <.board hexes={@hexes} viewer={@game.human} />
      </div>

      <div class="he-side">
        <div class="he-card">
          <div class="he-title">HEX EMPIRE</div>
          <div class="he-sub">
            Turn {@game.turns} · {Engine.faction_name(@game.turn_party)} moving
          </div>
        </div>

        <div :if={@game.winner != nil} class="he-over">{winner_text(@game)}</div>

        <div class="he-card">
          <div :for={p <- 0..3} class={pl_class(@game, p)}>
            <div class="he-swatch" style={"background:#{faction(p).color}"}></div>
            <div class="he-name">
              {faction(p).name}
              <span :if={p == @game.human} class="he-sub">(you)</span>
              <div class="he-sub">
                {status_name(@game, p)} · {Enum.at(@game.total_count, p)} troops
              </div>
            </div>
            <div class="he-bar">
              <div style={"width:#{min(100, Enum.at(@game.morale, p))}%;background:#{faction(p).color}"}>
              </div>
            </div>
            <div class="he-sub">{Enum.at(@game.morale, p)}</div>
          </div>
        </div>

        <div class="he-card" style="display:flex;flex-direction:column;gap:8px">
          <div class="he-status">{@status_msg}</div>
          <div :if={@game.winner == nil} class="he-sub">{advisor(@game.human_condition)}</div>
          <div :if={human_turn?(@game)} class="he-sub">
            Moves left: {@game.actions}
          </div>
          <button class="he-btn primary" phx-click="end_turn" disabled={not human_turn?(@game)}>
            End Turn
          </button>
        </div>

        <div class="he-card">
          <div class="he-sub" style="margin-bottom:6px">War report</div>
          <div class="he-log">
            <div :for={line <- @game.log}>· {line}</div>
            <div :if={@game.log == []} class="he-sub">All quiet on every front.</div>
          </div>
        </div>

        <form class="he-card" phx-submit="new_game" style="display:flex;flex-direction:column;gap:8px">
          <div class="he-sub">New campaign</div>
          <select name="faction" class="he-sel">
            <option :for={p <- 0..3} value={p} selected={p == @game.human}>
              Play {faction(p).name}
            </option>
          </select>
          <select name="difficulty" class="he-sel">
            <option value="0" selected={@difficulty == 0}>Easy</option>
            <option value="5" selected={@difficulty == 5}>Normal</option>
            <option value="10" selected={@difficulty == 10}>Hard</option>
          </select>
          <button type="submit" class="he-btn ghost">New Game</button>
        </form>

        <div class="he-card" style="display:flex;flex-direction:column;gap:8px">
          <div class="he-sub">
            Multiplayer — create a match, share the link, play over days.
          </div>
          <button class="he-btn ghost" phx-click="create_match">Create multiplayer match</button>
        </div>
      </div>
    </div>
    """
  end

  defp pl_class(g, p) do
    base = "he-pl"
    base = if g.turn_party == p and Enum.at(g.status, p) != 0, do: base <> " active", else: base
    if Enum.at(g.status, p) == 0, do: base <> " dead", else: base
  end
end
