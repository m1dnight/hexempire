defmodule HexEmpire.Matches.Match do
  @moduledoc """
  A multiplayer match: a shareable game identified by a short code, with the
  four engine parties mapped to seats.

  * `:lobby` — seats are being claimed; no game exists yet.
  * `:playing` — the game runs under the engine's spectator mode
    (`human: -1, spectating: true`): no human-biased AI branches, and victory
    goes to the sole controller of all original capitals. "Whose turn it is"
    and "who may move this party" are seat concerns enforced by the match
    server — the frozen engine knows nothing about seats.

  A seat is `%{kind, token, player_id}`:
  * `kind` — `:open` (claimable in the lobby), `:human`, or `:ai`
  * `token` — the seat's private rejoin credential (embedded in the personal
    link, so a player can resume from any device)
  * `player_id` — the session id of the browser most recently bound to the
    seat (a convenience so the plain match link resumes on the same browser)
  """

  alias HexEmpire.Engine

  @enforce_keys [:id, :status, :seats, :created_at]
  defstruct [:id, :status, :game, :seats, :host_token, :created_at, brutal_ai: false]

  @type seat :: %{
          kind: :open | :human | :ai,
          token: String.t() | nil,
          player_id: String.t() | nil
        }
  @type t :: %__MODULE__{
          id: String.t(),
          status: :lobby | :playing,
          game: Engine.game() | nil,
          seats: %{Engine.party() => seat()},
          host_token: String.t() | nil,
          created_at: integer(),
          brutal_ai: boolean()
        }

  # Short human-friendly code: lowercase base32 without look-alikes (i/l/1, o/0).
  @code_alphabet ~c"abcdefghjkmnpqrstuvwxyz23456789"

  @doc "A fresh lobby with four open seats."
  @spec new() :: t()
  def new do
    %__MODULE__{
      id: generate_id(),
      status: :lobby,
      game: nil,
      seats: Map.new(0..3, fn p -> {p, %{kind: :open, token: nil, player_id: nil}} end),
      host_token: nil,
      created_at: System.system_time(:second)
    }
  end

  @doc "Generate a 6-character match code."
  @spec generate_id() :: String.t()
  def generate_id do
    for _ <- 1..6, into: "", do: <<Enum.random(@code_alphabet)>>
  end

  @doc "Generate a seat rejoin token."
  @spec generate_token() :: String.t()
  def generate_token do
    Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  @doc "The party bound to `token`, or nil."
  @spec party_for_token(t(), String.t() | nil) :: Engine.party() | nil
  def party_for_token(_match, nil), do: nil

  def party_for_token(match, token) do
    Enum.find_value(match.seats, fn {party, seat} ->
      if seat.kind == :human and seat.token == token, do: party
    end)
  end

  @doc "The party most recently bound to the browser session `player_id`, or nil."
  @spec party_for_player(t(), String.t() | nil) :: Engine.party() | nil
  def party_for_player(_match, nil), do: nil

  def party_for_player(match, player_id) do
    Enum.find_value(match.seats, fn {party, seat} ->
      if seat.kind == :human and seat.player_id == player_id, do: party
    end)
  end

  @doc "Parties still claimable (lobby only)."
  @spec open_parties(t()) :: [Engine.party()]
  def open_parties(match) do
    for {party, %{kind: :open}} <- Enum.sort(match.seats), do: party
  end

  @doc """
  The AI module driving this match's computer seats. Read leniently
  (`Map.get`) so matches saved before the flag existed keep loading.
  """
  @spec ai_module(t()) :: module()
  def ai_module(match) do
    if Map.get(match, :brutal_ai, false),
      do: HexEmpire.Engine.TurnPlannerAi,
      else: HexEmpire.Engine.OriginalAi
  end

  @doc "True when the current turn belongs to an AI seat of a running match."
  @spec ai_turn?(t()) :: boolean()
  def ai_turn?(%__MODULE__{status: :playing, game: g} = match) do
    g.winner == nil and match.seats[g.turn_party].kind == :ai
  end

  def ai_turn?(_), do: false
end
