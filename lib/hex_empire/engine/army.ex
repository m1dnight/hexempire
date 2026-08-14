defmodule HexEmpire.Engine.Army do
  @moduledoc """
  Port of original/army.js. An army is a `%HexEmpire.Engine.Army{}` struct
  embedded in its field (`field.army`).

  (carriedFlags omitted — flags/domination mode is not ported; standard mode only.)
  Field order on the board defines army iteration order (see listArmies in the
  original: per-party arrays are rebuilt by scanning board fields).
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.Config

  @enforce_keys [:id, :party, :count, :morale]
  defstruct [:id, :party, :count, :morale, moved: false]

  @typedoc "An army, embedded in its field (`field.army`)."
  @type t :: %__MODULE__{
          id: pos_integer(),
          party: Engine.party(),
          count: non_neg_integer(),
          morale: non_neg_integer(),
          moved: boolean()
        }

  @doc "clampArmy: count into 0..99 (floored), morale into 0..count (floored)."
  @spec clamp(t()) :: t()
  def clamp(army) do
    count = army.count |> floor_int() |> max(0) |> min(Config.max_army())
    morale = army.morale |> floor_int() |> max(0) |> min(count)
    %{army | count: count, morale: morale}
  end

  @doc """
  createArmy: returns `{game, army | nil}` — places a new army on the field,
  consuming game.next_army_id. No-op (nil) when count <= 0.
  """
  @spec create(Engine.game(), Engine.field_key(), Engine.party(), number(), number()) ::
          {Engine.game(), t() | nil}
  def create(game, field_key, party, count, morale) do
    if count <= 0 do
      {game, nil}
    else
      id = game.next_army_id
      army = clamp(%__MODULE__{id: id, party: party, count: count, morale: morale, moved: false})
      game = put_army(%{game | next_army_id: id + 1}, field_key, army)
      {game, army}
    end
  end

  @doc "updateArmy: set/replace/remove (count<=0) the army on a field."
  @spec update(Engine.game(), Engine.field_key(), Engine.party(), number(), number()) ::
          {Engine.game(), t() | nil}
  def update(game, field_key, party, count, morale) do
    field = Map.fetch!(game.fields, field_key)

    cond do
      field.army == nil ->
        create(game, field_key, party, count, morale)

      count <= 0 ->
        {put_army(game, field_key, nil), nil}

      true ->
        army = clamp(%{field.army | party: party, count: count, morale: morale})
        {put_army(game, field_key, army), army}
    end
  end

  @doc "joinUnits: merge incoming troops into the field's army (weighted morale)."
  @spec join(Engine.game(), Engine.field_key(), Engine.party(), number(), number()) ::
          {Engine.game(), t() | nil}
  def join(game, field_key, party, count, morale) do
    field = Map.fetch!(game.fields, field_key)

    case field.army do
      nil ->
        create(game, field_key, party, count, morale)

      army ->
        total = army.count + count
        merged_morale = floor_int((army.count * army.morale + count * morale) / total)
        update(game, field_key, party, total, merged_morale)
    end
  end

  @doc """
  The single army-placement primitive. Also maintains `game.army_pos`
  (id => current field key) so that stale-list morale iteration (see
  Morale.add_for_all) can reach armies by identity, like the original's
  object references.
  """
  @spec put_army(Engine.game(), Engine.field_key(), t() | nil) :: Engine.game()
  def put_army(game, field_key, army_or_nil) do
    prev = Map.fetch!(game.fields, field_key).army

    pos = game.army_pos

    pos =
      case prev do
        %{id: id} -> if Map.get(pos, id) == field_key, do: Map.delete(pos, id), else: pos
        nil -> pos
      end

    pos =
      case army_or_nil do
        %{id: id} -> Map.put(pos, id, field_key)
        nil -> pos
      end

    %{
      game
      | fields: Map.update!(game.fields, field_key, &%{&1 | army: army_or_nil}),
        army_pos: pos
    }
  end

  defp floor_int(n) when is_integer(n), do: n
  defp floor_int(n), do: trunc(:math.floor(n))
end
