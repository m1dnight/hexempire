defmodule HexEmpireWeb.MatchLive do
  @moduledoc """
  Multiplayer match view at `/m/:id` — lobby (seat claiming) and the shared
  game board.

  All authority lives in the match's `MatchServer`; this LiveView renders the
  broadcast state and forwards seat-scoped commands with the seat's rejoin
  token. Seat resolution: a `?seat=<token>` personal link wins (and rebinds
  the browser session), else the session's previously bound seat, else the
  visitor is a claimant (lobby) or spectator (game).
  """

  use HexEmpireWeb, :live_view

  import HexEmpireWeb.BoardComponents,
    only: [board: 1, build_hexes: 4, faction: 1, action_bar: 1, base_url: 1, copy_link: 1]

  alias HexEmpire.{Engine, Matches}
  alias HexEmpire.Matches.Match

  @impl true
  def mount(%{"id" => id} = params, session, socket) do
    player_id = session["player_id"]

    case Matches.get(id) do
      nil ->
        {:ok, assign(socket, match: nil, id: id)}

      match ->
        if connected?(socket), do: Matches.subscribe(id)

        {token, party} = resolve_seat(match, params["seat"], player_id)

        {:ok,
         socket
         |> assign(
           id: id,
           match: match,
           player_id: player_id,
           token: token,
           party: party,
           base_url: base_url(socket),
           push_key: if(HexEmpire.Push.enabled?(), do: HexEmpire.Push.public_key()),
           push_state: :off,
           selected: nil,
           valid_moves: []
         )
         |> assign_board()}
    end
  end

  # Personal link token wins and rebinds the session; else the session's seat.
  defp resolve_seat(match, url_token, player_id) do
    case Match.party_for_token(match, url_token) do
      nil ->
        party = Match.party_for_player(match, player_id)
        token = if party, do: match.seats[party].token
        {token, party}

      party ->
        Matches.rebind(match.id, url_token, player_id)
        {url_token, party}
    end
  end

  # =========================================================================
  # Events
  # =========================================================================

  @impl true
  def handle_event("claim", %{"party" => party}, socket) do
    party = String.to_integer(party)

    case Matches.claim_seat(socket.assigns.id, party, socket.assigns.player_id) do
      {:ok, token} ->
        {:noreply, assign(socket, token: token, party: party)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_brutal", _params, socket) do
    Matches.set_brutal(socket.assigns.id, socket.assigns.token, not brutal?(socket.assigns.match))
    {:noreply, socket}
  end

  def handle_event("start", _params, socket) do
    Matches.start_match(socket.assigns.id, socket.assigns.token)
    {:noreply, socket}
  end

  def handle_event("hex", %{"k" => key}, socket) do
    %{match: match, party: party} = socket.assigns

    if my_turn?(match, party) do
      {:noreply, click(socket, match.game, key)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("end_turn", _params, socket) do
    Matches.end_turn(socket.assigns.id, socket.assigns.token)
    {:noreply, socket}
  end

  def handle_event("push_subscribed", sub, socket) do
    case Matches.set_push_sub(socket.assigns.id, socket.assigns.token, sub) do
      :ok -> {:noreply, assign(socket, push_state: :on)}
      _ -> {:noreply, assign(socket, push_state: :error)}
    end
  end

  def handle_event("push_denied", _params, socket) do
    {:noreply, assign(socket, push_state: :error)}
  end

  defp click(socket, g, key) do
    field = Map.fetch!(g.fields, key)
    sel = socket.assigns.selected
    party = socket.assigns.party

    cond do
      sel != nil and key in socket.assigns.valid_moves ->
        # Fire the command; the authoritative state arrives via {:match_updated, _}.
        Matches.move(socket.assigns.id, socket.assigns.token, sel, key)
        socket |> assign(selected: nil, valid_moves: []) |> assign_board()

      field.army != nil and field.army.party == party and not field.army.moved and
          g.actions > 0 ->
        socket
        |> assign(selected: key, valid_moves: Engine.possible_moves(g, key, true))
        |> assign_board()

      true ->
        socket |> assign(selected: nil, valid_moves: []) |> assign_board()
    end
  end

  # =========================================================================
  # PubSub
  # =========================================================================

  @impl true
  def handle_info({:match_updated, match}, socket) do
    # Selection survives only while it remains our turn on a live game.
    keep_selection? =
      match.status == :playing and my_turn?(match, socket.assigns.party) and
        socket.assigns.selected != nil

    socket =
      if keep_selection? do
        assign(socket, match: match)
      else
        assign(socket, match: match, selected: nil, valid_moves: [])
      end

    {:noreply, assign_board(socket)}
  end

  # =========================================================================
  # Board + view helpers
  # =========================================================================

  defp assign_board(%{assigns: %{match: %Match{status: :playing, game: g}}} = socket) do
    %{selected: sel, valid_moves: valid, party: party} = socket.assigns
    assign(socket, hexes: build_hexes(g, sel, valid, party))
  end

  defp assign_board(socket), do: socket

  defp my_turn?(%Match{status: :playing, game: g}, party) do
    party != nil and g.winner == nil and g.turn_party == party
  end

  defp my_turn?(_, _), do: false

  # Lenient read: matches saved before the flag existed lack the key.
  defp brutal?(match), do: Map.get(match, :brutal_ai, false)

  defp seat_label(%{kind: :open}), do: "Open seat"
  defp seat_label(%{kind: :ai}), do: "Computer"
  defp seat_label(%{kind: :human}), do: "Claimed"

  defp status_name(g, party) do
    s = Enum.at(g.status, party)
    if s == 0, do: "Defeated", else: Enum.at(Engine.status_names(), min(s, 4))
  end

  defp turn_banner(match, party) do
    g = match.game

    cond do
      g.winner != nil ->
        "🏆 #{Engine.faction_name(g.winner)} rules the world (#{g.victory_reason})."

      my_turn?(match, party) ->
        "Your move — #{g.actions} left."

      match.seats[g.turn_party].kind == :ai ->
        "#{Engine.faction_name(g.turn_party)} (computer) is moving…"

      true ->
        "Waiting for #{Engine.faction_name(g.turn_party)}…"
    end
  end

  defp match_url(base_url, id), do: "#{base_url}/m/#{id}"
  defp personal_url(base_url, id, token), do: "#{base_url}/m/#{id}?seat=#{token}"

  # =========================================================================
  # Render
  # =========================================================================

  @impl true
  def render(%{match: nil} = assigns) do
    ~H"""
    <div class="he-center">
      <div class="he-card" style="text-align:center">
        <div class="he-title">Match not found</div>
        <div class="he-sub">No match with code “{@id}”. It may have been deleted.</div>
        <a href="/" class="he-btn primary" style="display:inline-block;margin-top:10px">
          Back to Hex Empire
        </a>
      </div>
    </div>
    """
  end

  def render(%{match: %Match{status: :lobby}} = assigns) do
    ~H"""
    <div class="he-center">
      <div class="he-card" style="min-width:340px;max-width:440px">
        <div class="he-title">
          HEX EMPIRE — Match {@match.id}
          <span class="he-version">v{HexEmpireWeb.BoardComponents.version()}</span>
        </div>
        <div class="he-sub" style="margin-bottom:10px">
          Send this link to invite players — unclaimed factions play as computers.
        </div>
        <div style="margin-bottom:10px">
          <.copy_link url={match_url(@base_url, @id)} label="Invite link (click to copy):" />
        </div>

        <div :for={{party, seat} <- Enum.sort(@match.seats)} class="he-pl">
          <div class="he-swatch" style={"background:#{faction(party).color}"}></div>
          <div class="he-name">
            {faction(party).name}
            <span :if={@party == party} class="he-sub">(you)</span>
            <div class="he-sub">{seat_label(seat)}</div>
          </div>
          <button
            :if={seat.kind == :open and @party == nil}
            class="he-btn ghost"
            style="width:auto;padding:6px 10px"
            phx-click="claim"
            phx-value-party={party}
          >
            Claim
          </button>
        </div>

        <div :if={@party != nil} class="he-card" style="background:#22301c;margin-top:8px">
          <.copy_link
            url={personal_url(@base_url, @id, @token)}
            label="Your personal rejoin link (works on any device):"
          />
        </div>

        <div
          :if={@token != nil and @token == @match.host_token}
          class="he-card"
          style="background:#22301c;margin-top:8px;display:flex;align-items:center;gap:8px"
        >
          <div class="he-sub" style="flex:1">
            Computer strength: {if brutal?(@match), do: "Brutal (new AI)", else: "Classic"}
          </div>
          <button class="he-btn ghost" style="width:auto;padding:6px 10px" phx-click="toggle_brutal">
            Switch
          </button>
        </div>

        <button
          :if={@token != nil and @token == @match.host_token}
          class="he-btn primary"
          style="margin-top:10px"
          phx-click="start"
        >
          Start match
        </button>
        <div
          :if={@token != nil and @token != @match.host_token}
          class="he-sub"
          style="margin-top:10px"
        >
          Waiting for the host to start the match…
        </div>
      </div>
    </div>
    """
  end

  def render(%{match: %Match{status: :playing}} = assigns) do
    ~H"""
    <div class="he-root">
      <div class="he-board">
        <.board hexes={@hexes} viewer={@party} />
      </div>

      <.action_bar
        status={turn_banner(@match, @party)}
        moves={if my_turn?(@match, @party), do: @match.game.actions}
        can_end_turn={my_turn?(@match, @party)}
        show_button={@party != nil}
      />

      <div class="he-side">
        <div class="he-card">
          <div class="he-title">
            HEX EMPIRE <span class="he-version">v{HexEmpireWeb.BoardComponents.version()}</span>
          </div>
          <div class="he-sub">
            Match {@id} · Round {@match.game.turns} · {Engine.faction_name(@match.game.turn_party)} moving
          </div>
        </div>

        <div :if={@match.game.winner != nil} class="he-over">
          {turn_banner(@match, @party)}
        </div>

        <div class="he-card">
          <div :for={{party, seat} <- Enum.sort(@match.seats)} class={pl_class(@match.game, party)}>
            <div class="he-swatch" style={"background:#{faction(party).color}"}></div>
            <div class="he-name">
              {faction(party).name}
              <span :if={@party == party} class="he-sub">(you)</span>
              <span :if={seat.kind == :ai} class="he-sub">
                ({if brutal?(@match), do: "brutal computer", else: "computer"})
              </span>
              <div class="he-sub">
                {status_name(@match.game, party)} · {Enum.at(@match.game.total_count, party)} troops
              </div>
            </div>
            <div class="he-bar">
              <div style={"width:#{min(100, Enum.at(@match.game.morale, party))}%;background:#{faction(party).color}"}>
              </div>
            </div>
            <div class="he-sub">{Enum.at(@match.game.morale, party)}</div>
          </div>
        </div>

        <div class="he-card" style="display:flex;flex-direction:column;gap:8px">
          <div class="he-status">{turn_banner(@match, @party)}</div>
          <div :if={@party == nil} class="he-sub">You are spectating.</div>
          <button
            :if={@party != nil}
            class="he-btn primary"
            phx-click="end_turn"
            disabled={not my_turn?(@match, @party)}
          >
            End Turn
          </button>
          <button
            :if={@party != nil and @push_key != nil and @push_state != :on}
            id="push-subscribe"
            phx-hook="PushSubscribe"
            data-vapid={@push_key}
            class="he-btn ghost"
          >
            🔔 Notify me on my turn
          </button>
          <div :if={@push_state == :on} class="he-sub">🔔 Turn alerts enabled on this device.</div>
          <div :if={@push_state == :error} class="he-sub">Notifications blocked by the browser.</div>
        </div>

        <div class="he-card">
          <div class="he-sub" style="margin-bottom:6px">War report</div>
          <div class="he-log">
            <div :for={line <- @match.game.log}>· {line}</div>
            <div :if={@match.game.log == []} class="he-sub">All quiet on every front.</div>
          </div>
        </div>

        <div class="he-card">
          <.copy_link url={match_url(@base_url, @id)} label="Spectate/share link (click to copy):" />
          <div :if={@party != nil} style="margin-top:8px">
            <.copy_link
              url={personal_url(@base_url, @id, @token)}
              label="Your rejoin link (bookmark it to play from anywhere):"
            />
          </div>
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
