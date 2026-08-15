defmodule HexEmpire.Push do
  @moduledoc """
  Web Push turn notifications for multiplayer matches.

  Subscriptions are stored per seat on the match (they travel with the match
  save); the MatchServer calls the notify functions on turn transitions.
  Sending is fire-and-forget in a Task — push failures must never affect a
  running match. The actual sender is swappable (`:push_sender` config) so
  tests can capture sends without network access.
  """

  require Logger

  @sender Application.compile_env(:hex_empire, :push_sender, HexEmpire.Push.ExNudgeSender)

  @doc "The VAPID public key the browser needs to subscribe (nil when unconfigured)."
  @spec public_key() :: String.t() | nil
  def public_key, do: Application.get_env(:ex_nudge, :vapid_public_key)

  @doc "Push configured at all?"
  @spec enabled?() :: boolean()
  def enabled?, do: public_key() != nil

  @doc """
  Notify a seat that it's their turn. `sub` is the stored subscription map
  (`%{"endpoint" => _, "keys" => %{"p256dh" => _, "auth" => _}}`).
  """
  @spec notify_turn(map(), String.t(), String.t()) :: :ok
  def notify_turn(sub, match_id, faction_name) do
    send_async(sub, %{
      title: "Hex Empire — your move!",
      body: "#{faction_name} awaits your orders in match #{match_id}.",
      url: "/m/#{match_id}"
    })
  end

  @doc "Notify a seat that the match has been decided."
  @spec notify_match_over(map(), String.t(), String.t()) :: :ok
  def notify_match_over(sub, match_id, winner_name) do
    send_async(sub, %{
      title: "Hex Empire — match #{match_id} is over",
      body: "#{winner_name} rules the world.",
      url: "/m/#{match_id}"
    })
  end

  defp send_async(sub, payload) do
    Task.start(fn ->
      case @sender.send(sub, Jason.encode!(payload)) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("web push failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defmodule ExNudgeSender do
    @moduledoc false

    @spec send(map(), String.t()) :: :ok | {:error, term()}
    def send(sub, payload) do
      subscription = %ExNudge.Subscription{
        endpoint: sub["endpoint"],
        keys: %{
          p256dh: get_in(sub, ["keys", "p256dh"]),
          auth: get_in(sub, ["keys", "auth"])
        }
      }

      case ExNudge.send_notification(subscription, payload, ttl: 24 * 3600, urgency: :normal) do
        {:ok, _response} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
