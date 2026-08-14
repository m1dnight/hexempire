defmodule HexEmpire.Engine.Rng do
  @moduledoc """
  Bit-exact port of the original SWF LCG (original/random.js):

      seed = (seed * 9301 + 49297) % 233280
      nextInt(n) = floor((seed / 233280) * n)

  The float math is replicated exactly (IEEE-754 division first, then
  multiplication, then floor), because the original divides before multiplying.
  JS `%` is truncated remainder — same as Elixir's `rem/2`.

  The RNG is a plain integer threaded through the game state.
  """

  @m 233_280
  @a 9301
  @c 49_297

  @doc """
  JS `(Number(seed)||0)|0` — 32-bit signed truncation.

  Only integer inputs replicate the JS exactly; any non-integer collapses
  to 0. JS Number() string/float coercion ("123" -> 123, 12.7 -> 12 after
  `|0`) is intentionally not replicated — the engine only ever passes
  integers (sole call site: State.create_game).
  """
  @spec set_seed(term()) :: integer()
  def set_seed(seed) when is_integer(seed) do
    <<s::signed-32>> = <<seed::signed-32>>
    s
  end

  def set_seed(_), do: 0

  @doc "Returns `{value, new_seed}` exactly like the JS `nextInt(n)`."
  @spec next_int(integer(), integer()) :: {non_neg_integer(), integer()}
  def next_int(seed, n) when n <= 0, do: {0, seed}

  def next_int(seed, n) do
    seed2 = rem(seed * @a + @c, @m)
    value = trunc(:math.floor(seed2 / @m * n))
    {value, seed2}
  end

  @doc """
  The deliberately-not-Fisher-Yates SWF shuffle: for each index i in order,
  swap element i with element at nextInt(length).
  Returns `{shuffled_list, new_seed}`.
  """
  @spec shuffle(integer(), [elem]) :: {[elem], integer()} when elem: var
  def shuffle(seed, list) do
    len = length(list)
    arr = List.to_tuple(list)

    {arr, seed} =
      Enum.reduce(0..(len - 1)//1, {arr, seed}, fn i, {a, s} ->
        {rn, s2} = next_int(s, len)
        vi = elem(a, i)
        vr = elem(a, rn)
        {a |> put_elem(i, vr) |> put_elem(rn, vi), s2}
      end)

    {Tuple.to_list(arr), seed}
  end
end
