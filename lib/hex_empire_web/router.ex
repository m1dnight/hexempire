defmodule HexEmpireWeb.Router do
  use HexEmpireWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HexEmpireWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :ensure_player_id
  end

  # A stable per-browser id in the signed session; keys saved games.
  defp ensure_player_id(conn, _opts) do
    case Plug.Conn.get_session(conn, "player_id") do
      nil ->
        id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
        Plug.Conn.put_session(conn, "player_id", id)

      _ ->
        conn
    end
  end

  scope "/", HexEmpireWeb do
    pipe_through :browser

    live "/", GameLive, :index
    live "/m/:id", MatchLive, :show
  end
end
