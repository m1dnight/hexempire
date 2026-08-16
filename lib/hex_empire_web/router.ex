defmodule HexEmpireWeb.Router do
  use HexEmpireWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HexEmpireWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :ensure_ids
  end

  # Stable ids in the signed session:
  #  * player_id   — identifies the browser (multiplayer seat convenience binding)
  #  * campaign_id — keys the solo campaign save; it defaults to player_id so
  #    pre-existing campaigns keep working, and /c/:token can rebind any
  #    browser (installed PWA, another device) to an existing campaign.
  defp ensure_ids(conn, _opts) do
    conn =
      case Plug.Conn.get_session(conn, "player_id") do
        nil ->
          id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
          Plug.Conn.put_session(conn, "player_id", id)

        _ ->
          conn
      end

    case Plug.Conn.get_session(conn, "campaign_id") do
      nil ->
        Plug.Conn.put_session(
          conn,
          "campaign_id",
          Plug.Conn.get_session(conn, "player_id")
        )

      _ ->
        conn
    end
  end

  scope "/", HexEmpireWeb do
    pipe_through :browser

    live "/", GameLive, :index
    live "/m/:id", MatchLive, :show
    get "/c/:token", CampaignController, :resume
  end
end
