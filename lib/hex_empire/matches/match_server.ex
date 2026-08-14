defmodule HexEmpire.Matches.MatchServer do
  @moduledoc """
  The single authority for one running match.

  Owns the `%Match{}`, validates every seat-scoped command, drives AI seats
  on its own timer (so the game advances even with nobody connected),
  persists synchronously after every mutation, and broadcasts the updated
  match on `"match:<id>"` via PubSub.

  Started on demand through `HexEmpire.Matches.ensure_started/1` (Registry +
  DynamicSupervisor); hibernates its state to disk and stops after 30 minutes
  without messages — the next visitor lazily restarts it from the store. If
  it stops (or the node restarts) mid-AI-turn, `init/1` reschedules the AI
  tick and play resumes.
  """

  use GenServer, restart: :transient

  alias HexEmpire.Engine
  alias HexEmpire.Matches.{Match, MatchStore}

  # AI cadence in a match (slower than solo so all watchers can follow).
  @ai_delay Application.compile_env(:hex_empire, :match_ai_delay, 600)
  @idle_ms 30 * 60 * 1000

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  def start_link(id) do
    GenServer.start_link(__MODULE__, id, name: via(id))
  end

  @doc "Registry name for a match id."
  def via(id), do: {:via, Registry, {HexEmpire.MatchRegistry, id}}

  @impl true
  def init(id) do
    case MatchStore.load(id) do
      %Match{} = match ->
        if Match.ai_turn?(match), do: schedule_ai()
        {:ok, match, @idle_ms}

      nil ->
        # Brand-new match created under this id by Matches.create/0.
        match = %{Match.new() | id: id}
        MatchStore.save(match)
        {:ok, match, @idle_ms}
    end
  end

  # ---------------------------------------------------------------------------
  # Calls
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call(:get, _from, match), do: {:reply, match, match, @idle_ms}

  def handle_call({:claim_seat, party, player_id}, _from, match) do
    with :lobby <- match.status,
         %{kind: :open} <- match.seats[party] do
      token = Match.generate_token()
      seat = %{kind: :human, token: token, player_id: player_id}
      match = %{match | seats: Map.put(match.seats, party, seat)}
      match = if match.host_token == nil, do: %{match | host_token: token}, else: match
      {:reply, {:ok, token}, persist_and_broadcast(match), @idle_ms}
    else
      _ -> {:reply, {:error, :unavailable}, match, @idle_ms}
    end
  end

  def handle_call({:rebind, token, player_id}, _from, match) do
    case Match.party_for_token(match, token) do
      nil ->
        {:reply, :error, match, @idle_ms}

      party ->
        seat = %{match.seats[party] | player_id: player_id}
        match = %{match | seats: Map.put(match.seats, party, seat)}
        MatchStore.save(match)
        {:reply, {:ok, party}, match, @idle_ms}
    end
  end

  def handle_call({:start, token}, _from, match) do
    cond do
      match.status != :lobby ->
        {:reply, {:error, :already_started}, match, @idle_ms}

      token != match.host_token or token == nil ->
        {:reply, {:error, :not_host}, match, @idle_ms}

      true ->
        # Unclaimed seats become AI. The engine runs in spectator mode: no
        # human party, victory to the sole controller of all capitals.
        seats =
          Map.new(match.seats, fn
            {p, %{kind: :open}} -> {p, %{kind: :ai, token: nil, player_id: nil}}
            {p, seat} -> {p, seat}
          end)

        game =
          Engine.new_game(seed: :rand.uniform(999_999), human: -1, spectating: true)

        match = %{match | status: :playing, seats: seats, game: game}
        if Match.ai_turn?(match), do: schedule_ai()
        {:reply, :ok, persist_and_broadcast(match), @idle_ms}
    end
  end

  def handle_call({:move, token, from, to}, _from, match) do
    with {:party, party} when party != nil <- {:party, Match.party_for_token(match, token)},
         {:turn, true} <- {:turn, seat_may_act?(match, party)},
         {:valid, true} <- {:valid, valid_move?(match.game, party, from, to)} do
      {g, _result} = Engine.move(match.game, from, to)
      g = if g.actions <= 0 and g.winner == nil, do: Engine.end_turn(g), else: g
      match = %{match | game: g}
      if Match.ai_turn?(match), do: schedule_ai()
      {:reply, :ok, persist_and_broadcast(match), @idle_ms}
    else
      _ -> {:reply, {:error, :invalid}, match, @idle_ms}
    end
  end

  def handle_call({:end_turn, token}, _from, match) do
    party = Match.party_for_token(match, token)

    if party != nil and seat_may_act?(match, party) do
      match = %{match | game: Engine.end_turn(match.game)}
      if Match.ai_turn?(match), do: schedule_ai()
      {:reply, :ok, persist_and_broadcast(match), @idle_ms}
    else
      {:reply, {:error, :invalid}, match, @idle_ms}
    end
  end

  # ---------------------------------------------------------------------------
  # AI driving + idle shutdown
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:ai_tick, match) do
    if Match.ai_turn?(match) do
      match = %{match | game: ai_step(match.game)}
      if Match.ai_turn?(match), do: schedule_ai()
      {:noreply, persist_and_broadcast(match), @idle_ms}
    else
      {:noreply, match, @idle_ms}
    end
  end

  # GenServer idle timeout: state is already on disk, so just stop; the next
  # visitor restarts the server from the store.
  def handle_info(:timeout, match), do: {:stop, :normal, match}

  # One AI action, finishing the turn when the step yields nothing, the
  # budget is spent, or no movable armies remain (same reduction as
  # Campaigns.ai_step; a game decided mid-step skips the finish).
  defp ai_step(g) do
    {g, result} =
      if g.actions > 0 and Engine.movable_armies(g) != [] do
        Engine.ai_step(g)
      else
        {g, nil}
      end

    if result == nil or g.actions <= 0 or Engine.movable_armies(g) == [] do
      if g.winner == nil or g.screen == :game, do: Engine.end_turn(g), else: g
    else
      g
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seat_may_act?(%Match{status: :playing, game: g}, party) do
    g.winner == nil and g.turn_party == party
  end

  defp seat_may_act?(_, _), do: false

  defp valid_move?(g, party, from, to) do
    origin = Map.get(g.fields, from)

    g.actions > 0 and origin != nil and origin.army != nil and
      origin.army.party == party and not origin.army.moved and
      to in Engine.possible_moves(g, from, true)
  end

  defp schedule_ai, do: Process.send_after(self(), :ai_tick, @ai_delay)

  defp persist_and_broadcast(match) do
    MatchStore.save(match)
    Phoenix.PubSub.broadcast(HexEmpire.PubSub, "match:#{match.id}", {:match_updated, match})
    match
  end
end
