defmodule HexEmpire.Matches.MatchStore do
  @moduledoc """
  Disk persistence for matches (`<save_dir>/matches/<id>.bin`,
  `{:v1, %Match{}}` via `term_to_binary`).

  Plain module, no process: each match's file is written only by its own
  `MatchServer`, which serializes writes by construction. Matches are
  slow-paced, so synchronous write-through (no debounce) is the right
  trade-off — a crash never loses more than the in-flight mutation.
  """

  require Logger

  alias HexEmpire.Matches.Match

  @version :v1

  @doc "Persist a match."
  @spec save(Match.t()) :: :ok
  def save(%Match{} = match) do
    File.mkdir_p!(dir())

    case File.write(path(match.id), :erlang.term_to_binary({@version, match})) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("match save failed for #{match.id}: #{inspect(reason)}")
    end

    :ok
  end

  @doc "Load a match; nil when absent, unreadable, or from an old format."
  @spec load(String.t()) :: Match.t() | nil
  def load(id) when is_binary(id) do
    with {:ok, bin} <- File.read(path(id)),
         {@version, %Match{} = match} <- decode(bin) do
      match
    else
      _ -> nil
    end
  end

  def load(_), do: nil

  @doc "Remove a match's save."
  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    File.rm(path(id))
    :ok
  end

  defp decode(bin) do
    :erlang.binary_to_term(bin)
  rescue
    _ -> nil
  end

  defp dir do
    base = Application.get_env(:hex_empire, :save_dir) || Path.expand("saves")
    Path.join(base, "matches")
  end

  defp path(id) do
    Path.join(dir(), String.replace(id, ~r/[^a-z0-9]/, "") <> ".bin")
  end
end
