defmodule HexEmpireWeb.CampaignController do
  @moduledoc """
  Campaign resume links: `/c/<token>` rebinds this browser's session to an
  existing solo campaign (the token IS the campaign's save key), then heads
  to the game. Lets a campaign continue on any device or browser — including
  the installed PWA, which has its own cookie jar.
  """

  use HexEmpireWeb, :controller

  def resume(conn, %{"token" => token}) do
    case HexEmpire.GameStore.fetch(token) do
      nil ->
        conn
        |> put_flash(:error, "That campaign link doesn't match any saved game.")
        |> redirect(to: ~p"/")

      _campaign ->
        conn
        |> put_session("campaign_id", token)
        |> redirect(to: ~p"/")
    end
  end
end
