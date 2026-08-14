defmodule HexEmpire.GameStore do
  @moduledoc """
  Per-player persistence for running games.

  Games are keyed by a random `player_id` living in the browser's signed
  session cookie. State is kept in ETS for fast access (synchronous
  write-through in the caller) and mirrored to disk (`saves/<player_id>.bin`)
  so campaigns survive both browser refreshes and server restarts.

  Policies:

    * Disk writes are debounced per player: each save records the latest
      state in the GenServer and arms a short timer; only the newest state is
      written when it fires (and any still-pending states are written on
      terminate). This keeps the AI's rapid per-step saves from hammering
      the disk.
    * Save files are version-tagged (`{:v2, state}` via
      `:erlang.term_to_binary/1`); untagged, corrupt, or unreadable files are
      treated as absent so stale formats can never half-load. `:v2` marks the
      engine's struct migration (`%Game{}`/`%Field{}`/`%Army{}`) — older
      plain-map `:v1` saves are cleanly discarded.
    * Deletes run through the GenServer, serializing them behind any queued
      save casts — a pending flush can never resurrect a deleted campaign.
    * The ETS cache dies with the GenServer; disk survives and repopulates
      the cache on the next fetch.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @save_version :v2

  # Per-player debounce delay for disk writes (test config shrinks it).
  @flush_after_ms Application.compile_env(:hex_empire, :game_store_flush_ms, 1_000)

  # ---------------------------------------------------------------------------
  # API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Fetch a player's saved state (ETS first, disk fallback). nil when absent."
  @spec fetch(term()) :: map() | nil
  def fetch(player_id) when is_binary(player_id) do
    case :ets.lookup(@table, player_id) do
      [{^player_id, state}] ->
        state

      [] ->
        case File.read(save_path(player_id)) do
          {:ok, bin} ->
            try do
              case :erlang.binary_to_term(bin) do
                {@save_version, state} ->
                  :ets.insert(@table, {player_id, state})
                  state

                _other_format ->
                  nil
              end
            rescue
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  def fetch(_), do: nil

  @doc "Save a player's state (ETS immediately, disk write debounced)."
  @spec save(String.t(), map()) :: :ok
  def save(player_id, state) when is_binary(player_id) do
    :ets.insert(@table, {player_id, state})
    GenServer.cast(__MODULE__, {:save, player_id, state})
    :ok
  end

  @doc """
  Remove a player's save from both ETS and disk. Serialized through the
  GenServer so it also drops any pending debounced write.
  """
  @spec delete(String.t()) :: :ok
  def delete(player_id) when is_binary(player_id) do
    GenServer.call(__MODULE__, {:delete, player_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  # State: pending player_id => game-state awaiting its debounced disk write,
  # timers player_id => armed flush timer ref.

  @impl true
  def init(_opts) do
    # Trap exits so terminate/2 runs on supervisor shutdown and flushes
    # pending writes.
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    File.mkdir_p!(save_dir())
    {:ok, %{pending: %{}, timers: %{}}}
  end

  @impl true
  def handle_cast({:save, player_id, state}, store) do
    timers =
      if Map.has_key?(store.timers, player_id) do
        store.timers
      else
        ref = Process.send_after(self(), {:flush, player_id}, @flush_after_ms)
        Map.put(store.timers, player_id, ref)
      end

    {:noreply, %{store | pending: Map.put(store.pending, player_id, state), timers: timers}}
  end

  @impl true
  def handle_call({:delete, player_id}, _from, store) do
    case Map.fetch(store.timers, player_id) do
      {:ok, ref} -> Process.cancel_timer(ref)
      :error -> :ok
    end

    :ets.delete(@table, player_id)
    File.rm(save_path(player_id))

    {:reply, :ok,
     %{
       store
       | pending: Map.delete(store.pending, player_id),
         timers: Map.delete(store.timers, player_id)
     }}
  end

  @impl true
  def handle_info({:flush, player_id}, store) do
    case Map.fetch(store.pending, player_id) do
      {:ok, state} -> write(player_id, state)
      # already deleted (or flushed early by a stale timer message)
      :error -> :ok
    end

    {:noreply,
     %{
       store
       | pending: Map.delete(store.pending, player_id),
         timers: Map.delete(store.timers, player_id)
     }}
  end

  @impl true
  def terminate(_reason, store) do
    Enum.each(store.pending, fn {player_id, state} -> write(player_id, state) end)
  end

  defp write(player_id, state) do
    path = save_path(player_id)

    case File.write(path, :erlang.term_to_binary({@save_version, state})) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("GameStore: failed to write save #{path}: #{inspect(reason)}")
    end
  end

  defp save_dir do
    Application.get_env(:hex_empire, :save_dir) || Path.expand("saves")
  end

  defp save_path(player_id) do
    # player ids are hex strings we generate ourselves; sanitize anyway
    Path.join(save_dir(), String.replace(player_id, ~r/[^A-Za-z0-9_-]/, "") <> ".bin")
  end
end
