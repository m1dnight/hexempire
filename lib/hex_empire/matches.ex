defmodule HexEmpire.Matches do
  @moduledoc """
  Multiplayer matches: shareable slow games identified by a short code.

  The flow: `create/0` a lobby and share `/m/<id>`; visitors `claim_seat/3`
  (getting a private rejoin token for their personal link); the host
  `start_match/2` — unclaimed seats become AI. Seat holders `move/4` and
  `end_turn/2` on their party's turn; everyone (players and spectators)
  receives `{:match_updated, match}` after `subscribe/1`.

  Each match is owned by one `MatchServer` (Registry + DynamicSupervisor),
  started lazily from disk — matches survive browser closes, server
  restarts, and days between moves.
  """

  alias HexEmpire.Engine
  alias HexEmpire.Matches.{Match, MatchServer, MatchStore}

  @doc "Create a new match lobby; returns its id."
  @spec create() :: String.t()
  def create do
    id = Match.generate_id()

    case start_server(id) do
      {:ok, _pid} -> id
      # astronomically unlikely id collision with a live match: retry
      {:error, {:already_started, _}} -> create()
    end
  end

  @doc """
  Ensure the match's server is running (lazily loading it from disk).
  Returns `:ok` or `:not_found` (no live server and no save).
  """
  @spec ensure_started(String.t()) :: :ok | :not_found
  def ensure_started(id) when is_binary(id) do
    cond do
      Registry.lookup(HexEmpire.MatchRegistry, id) != [] -> :ok
      MatchStore.load(id) == nil -> :not_found
      true -> start_or_ok(id)
    end
  end

  def ensure_started(_), do: :not_found

  @doc "The current match state, or nil."
  @spec get(String.t()) :: Match.t() | nil
  def get(id) do
    case call(id, :get) do
      {:error, :not_found} -> nil
      match -> match
    end
  end

  @doc "Claim an open seat (lobby only). Returns `{:ok, rejoin_token}`."
  @spec claim_seat(String.t(), Engine.party(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def claim_seat(id, party, player_id) do
    call(id, {:claim_seat, party, player_id})
  end

  @doc "Bind the current browser session to the seat owning `token`."
  @spec rebind(String.t(), String.t(), String.t() | nil) :: {:ok, Engine.party()} | :error
  def rebind(id, token, player_id) do
    call(id, {:rebind, token, player_id})
  end

  @doc "Start the match (host only): unclaimed seats become AI."
  @spec start_match(String.t(), String.t()) :: :ok | {:error, term()}
  def start_match(id, token), do: call(id, {:start, token})

  @doc "Move the seat's army (validated server-side; auto-ends spent turns)."
  @spec move(String.t(), String.t(), Engine.field_key(), Engine.field_key()) ::
          :ok | {:error, term()}
  def move(id, token, from, to), do: call(id, {:move, token, from, to})

  @doc "End the seat's turn."
  @spec end_turn(String.t(), String.t()) :: :ok | {:error, term()}
  def end_turn(id, token), do: call(id, {:end_turn, token})

  @doc "Store the seat's Web Push subscription (turn notifications)."
  @spec set_push_sub(String.t(), String.t(), map()) :: :ok | :error | {:error, term()}
  def set_push_sub(id, token, sub), do: call(id, {:set_push_sub, token, sub})

  @doc "Subscribe the calling process to `{:match_updated, match}` broadcasts."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(id) do
    Phoenix.PubSub.subscribe(HexEmpire.PubSub, "match:#{id}")
  end

  defp call(id, msg, retry? \\ true) do
    with :ok <- ensure_started(id) do
      GenServer.call(MatchServer.via(id), msg)
    else
      _ -> {:error, :not_found}
    end
  catch
    # The server died between the Registry lookup and the call (e.g. idle
    # shutdown, or its Registry entry hadn't been cleaned up yet). State is
    # on disk — restart once and retry.
    :exit, {reason, _} when retry? and reason in [:noproc, :normal, :shutdown] ->
      Process.sleep(20)
      call(id, msg, false)
  end

  defp start_or_ok(id) do
    case start_server(id) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :not_found
    end
  end

  defp start_server(id) do
    DynamicSupervisor.start_child(HexEmpire.MatchSupervisor, {MatchServer, id})
  end
end
