defmodule HexEmpire.GameStoreTest do
  use ExUnit.Case, async: false

  alias HexEmpire.GameStore

  # Disk writes are debounced (:game_store_flush_ms, 25ms in test config), so
  # tests poll for the flush instead of synchronizing on the GenServer.
  @flush_ms Application.compile_env!(:hex_empire, :game_store_flush_ms)

  defp await(fun, deadline_ms \\ 1_000) do
    cond do
      fun.() ->
        :ok

      deadline_ms <= 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        await(fun, deadline_ms - 10)
    end
  end

  defp save_path(player_id) do
    dir = Application.get_env(:hex_empire, :save_dir)
    Path.join(dir, player_id <> ".bin")
  end

  test "falls back to disk after the ETS entry is gone" do
    id = "store-test-disk-fallback"
    on_exit(fn -> GameStore.delete(id) end)

    GameStore.save(id, %{game: :from_disk})
    await(fn -> File.exists?(save_path(id)) end)

    :ets.delete(GameStore, id)
    assert GameStore.fetch(id) == %{game: :from_disk}
  end

  test "debounce coalesces rapid saves; the latest state wins on disk" do
    id = "store-test-debounce"
    on_exit(fn -> GameStore.delete(id) end)

    GameStore.save(id, %{game: :stale})
    GameStore.save(id, %{game: :fresh})
    await(fn -> File.exists?(save_path(id)) end)

    :ets.delete(GameStore, id)
    assert GameStore.fetch(id) == %{game: :fresh}
  end

  test "a corrupt save file yields nil" do
    id = "store-test-corrupt"
    on_exit(fn -> GameStore.delete(id) end)

    File.write!(save_path(id), "not a term_to_binary payload")
    assert GameStore.fetch(id) == nil
  end

  test "an old-format (untagged) save file yields nil" do
    id = "store-test-untagged"
    on_exit(fn -> GameStore.delete(id) end)

    File.write!(save_path(id), :erlang.term_to_binary(%{game: :pre_versioning}))
    assert GameStore.fetch(id) == nil
  end

  test "delete removes both the ETS entry and the disk file" do
    id = "store-test-delete"

    GameStore.save(id, %{game: :doomed})
    await(fn -> File.exists?(save_path(id)) end)

    GameStore.delete(id)
    refute File.exists?(save_path(id))
    assert :ets.lookup(GameStore, id) == []
    assert GameStore.fetch(id) == nil
  end

  test "delete during a pending (debounced) flush stays deleted" do
    id = "store-test-delete-race"

    GameStore.save(id, %{game: :doomed})
    GameStore.delete(id)

    # wait out the debounce window — the dropped flush must not resurrect the file
    Process.sleep(@flush_ms * 4)
    refute File.exists?(save_path(id))
    assert GameStore.fetch(id) == nil
  end

  test "fetch with a non-binary id is nil" do
    assert GameStore.fetch(nil) == nil
    assert GameStore.fetch(123) == nil
  end
end
