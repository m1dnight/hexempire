defmodule HexEmpireWeb.BoardComponents do
  @moduledoc """
  Shared board rendering for the solo (`GameLive`) and multiplayer
  (`MatchLive`) views: the SVG hex board plus its settlement/army tokens,
  and the `build_hexes/4` precomputation that turns an engine game into
  renderable hex data.

  Geometry matches the original: 50x40 fields, 37.5 x-step, odd columns
  shifted down half a tile.
  """

  use Phoenix.Component

  alias HexEmpire.Engine

  @fw 50
  @fh 40
  @xstep 37.5

  # 2.5D: land tiles extrude downward by this many px (water stays flat/low).
  @depth 6

  @doc "SVG viewBox width for the 20x11 board."
  def viewbox_w, do: 19 * @xstep + @fw

  @doc "SVG viewBox height for the 20x11 board (incl. tile extrusion depth)."
  def viewbox_h, do: 11 * @fh + @fh / 2 + @depth + 2

  @doc """
  Precompute renderable hex data for a game.

  `viewer` is the party the viewer controls (dims their moved armies and
  colors attack/merge highlights relative to them); nil for spectators.
  """
  def build_hexes(game, selected, valid_moves, viewer) do
    valid = MapSet.new(valid_moves)

    for key <- game.field_order do
      f = Map.fetch!(game.fields, key)
      {cx, cy} = position(f.x, f.y)
      land? = f.type == :land
      {top, side} = tile_style(f)

      %{
        key: key,
        cx: cx,
        cy: cy,
        points: hex_points(cx, cy),
        shadow_points: hex_points(cx, cy + @depth),
        shadow_fill: if(land?, do: side, else: "#2a5c8f"),
        top_fill: top,
        deco: deco(f),
        wave_delay: unless(land?, do: "#{rem(:erlang.phash2({f.x, f.y, :wave}), 3900)}ms"),
        type: f.type,
        estate: f.estate,
        capital: f.capital,
        party: f.party,
        town_name: f.town_name,
        army: f.army,
        selected: selected == key,
        valid: MapSet.member?(valid, key),
        attack: MapSet.member?(valid, key) and f.army != nil and f.army.party != viewer,
        merge: MapSet.member?(valid, key) and f.army != nil and f.army.party == viewer
      }
    end
  end

  attr :hexes, :list, required: true
  attr :viewer, :integer, default: nil, doc: "party whose moved armies render dimmed"

  @doc """
  The complete SVG game board, wrapped in the BoardZoom hook (pinch-zoom,
  drag-pan, wheel zoom, double-tap zoom — see assets/js/board_zoom.js).
  """
  def board(assigns) do
    assigns = assign(assigns, vb_w: viewbox_w(), vb_h: viewbox_h())

    ~H"""
    <div id="board-zoom" phx-hook="BoardZoom" class="he-zoom">
      <.board_svg hexes={@hexes} viewer={@viewer} vb_w={@vb_w} vb_h={@vb_h} />
      <div class="he-zoomctl">
        <button type="button" data-zoom="in" aria-label="Zoom in">+</button>
        <button type="button" data-zoom="out" aria-label="Zoom out">−</button>
        <button type="button" data-zoom="reset" aria-label="Fit board" class="he-zoomreset">⛶</button>
      </div>
    </div>
    """
  end

  attr :hexes, :list, required: true
  attr :viewer, :integer, default: nil
  attr :vb_w, :any, required: true
  attr :vb_h, :any, required: true

  defp board_svg(assigns) do
    ~H"""
    <svg viewBox={"0 0 #{@vb_w} #{@vb_h}"} class="he-svg" preserveAspectRatio="xMidYMid meet">
      <%!-- painter's layering: water floor -> land block shadows -> land tops.
           The "coastline lip" is each land tile's own silhouette translated
           down: joins are perfect by construction, and water needs no
           internal borders so lakes read as one body. --%>
      <%!-- water cross-section: visible only along the board's outer edge --%>
      <polygon
        :for={hx <- @hexes}
        :if={hx.type == :water}
        points={hx.shadow_points}
        fill={hx.shadow_fill}
        style="pointer-events:none"
      />
      <g :for={hx <- @hexes} :if={hx.type == :water}>
        <polygon
          points={hx.points}
          fill={hx.top_fill}
          stroke={hx.top_fill}
          stroke-width="0.6"
          class="he-hex"
          phx-click="hex"
          phx-value-k={hx.key}
        />
        <path
          d={wave_path(hx.cx, hx.cy)}
          class="he-wave"
          style={"animation-delay:#{hx.wave_delay};pointer-events:none"}
        />
        <.army_token :if={hx.army != nil} hx={hx} viewer={@viewer} />
      </g>
      <polygon
        :for={hx <- @hexes}
        :if={hx.type == :land}
        points={hx.shadow_points}
        fill={hx.shadow_fill}
        style="pointer-events:none"
      />
      <g :for={hx <- @hexes} :if={hx.type == :land}>
        <polygon
          points={hx.points}
          fill={hx.top_fill}
          stroke="#00000022"
          stroke-width="0.8"
          class="he-hex"
          phx-click="hex"
          phx-value-k={hx.key}
        />
        <.terrain :if={hx.deco != nil and hx.army == nil} hx={hx} />
        <.settlement :if={hx.estate != nil} hx={hx} />
        <.army_token :if={hx.army != nil} hx={hx} viewer={@viewer} />
      </g>
      <%!-- overlays last: reachable-glow and the selection outline --%>
      <g :for={hx <- @hexes} :if={hx.valid or hx.selected} style="pointer-events:none">
        <polygon
          :if={hx.valid}
          points={hx.points}
          fill={
            cond do
              hx.attack -> "#ff4040"
              hx.merge -> "#4f8fff"
              true -> "#ffe95c"
            end
          }
          stroke={
            cond do
              hx.attack -> "#a80000"
              hx.merge -> "#1852c9"
              true -> "#c9a400"
            end
          }
          stroke-width="2.5"
          class="he-glow"
        />
        <polygon :if={hx.selected} points={hx.points} fill="none" stroke="#ffe000" stroke-width="3.5" />
      </g>
    </svg>
    """
  end

  @doc "Faction metadata by party id."
  def faction(party), do: Enum.at(Engine.factions(), party)

  # Captured at compile time so it also works inside releases (no Mix there).
  @version Mix.Project.config()[:version]

  @doc "The application version (from mix.exs), e.g. \"0.0.1\"."
  def version, do: @version

  @doc """
  The absolute URL prefix as the visitor sees it (proxy hostname, LAN IP,
  tunnel, ...), so shared links are copy-pasteable full URLs. Falls back to
  the endpoint's configured URL.
  """
  def base_url(socket) do
    case socket.host_uri do
      %URI{} = uri -> uri |> URI.to_string() |> String.trim_trailing("/")
      _ -> HexEmpireWeb.Endpoint.url()
    end
  end

  attr :url, :string, required: true
  attr :label, :string, required: true

  @doc """
  A full URL with a tap-to-copy affordance (inline clipboard JS — no hook
  needed; degrades gracefully where the Clipboard API is unavailable).
  """
  def copy_link(assigns) do
    ~H"""
    <div class="he-sub">{@label}</div>
    <code
      class="he-code"
      title="Click to copy"
      onclick="navigator.clipboard && navigator.clipboard.writeText(this.dataset.url).then(() => { this.classList.add('he-copied'); setTimeout(() => this.classList.remove('he-copied'), 1200); })"
      data-url={@url}
    >
      {@url}
    </code>
    """
  end

  attr :status, :string, required: true
  attr :moves, :integer, default: nil, doc: "moves left, shown when it's the viewer's turn"
  attr :can_end_turn, :boolean, default: false
  attr :show_button, :boolean, default: true

  @doc """
  Bottom-fixed action bar for small screens (hidden on desktop via CSS):
  the turn status, remaining moves, and End Turn always within thumb reach.
  """
  def action_bar(assigns) do
    ~H"""
    <div class="he-actionbar">
      <div class="he-actionbar-status">
        <div class="he-status">{@status}</div>
        <div :if={@moves != nil} class="he-sub">Moves left: {@moves}</div>
      </div>
      <button
        :if={@show_button}
        class="he-btn primary"
        style="width:auto;flex:none"
        phx-click="end_turn"
        disabled={not @can_end_turn}
      >
        End Turn
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Geometry
  # ---------------------------------------------------------------------------

  defp position(x, y) do
    px = x * @xstep + @fw / 2
    py = y * @fh + if(rem(x, 2) != 0, do: @fh, else: @fh / 2)
    {px, py}
  end

  defp hex_points(cx, cy) do
    [
      {cx - 25, cy},
      {cx - 12.5, cy - 20},
      {cx + 12.5, cy - 20},
      {cx + 25, cy},
      {cx + 12.5, cy + 20},
      {cx - 12.5, cy + 20}
    ]
    |> Enum.map_join(" ", fn {x, y} -> "#{x},#{y}" end)
  end

  # ---------------------------------------------------------------------------
  # 2.5D tile styling (all deterministic from coordinates — cosmetic only,
  # NEVER touches the gameplay RNG)
  # ---------------------------------------------------------------------------

  # {top-fill variants, side-fill} per owner; a coordinate hash picks the
  # variant so the terrain has quiet texture instead of flat fills.
  @water_tops ["#3f82c4", "#3d7fc0", "#4184c6"]
  @tiles %{
    -1 => {["#e3d9b0", "#dcd2a8", "#d6cb9f"], "#a5986e"},
    0 => {["#eab5ac", "#e5aca2", "#efbeb5"], "#b0776d"},
    1 => {["#e3aede", "#dda5d8", "#e9b8e4"], "#a973a4"},
    2 => {["#adc4d8", "#a3bacf", "#b6cde0"], "#75909f"},
    3 => {["#b2dcaa", "#a9d5a0", "#bce3b4"], "#7aa572"}
  }

  defp tile_style(%{type: :water} = f) do
    {Enum.at(@water_tops, rem(:erlang.phash2({f.x, f.y, :tile}), 3)), nil}
  end

  defp tile_style(f) do
    {tops, side} = Map.fetch!(@tiles, f.party)
    {Enum.at(tops, rem(:erlang.phash2({f.x, f.y, :tile}), 3)), side}
  end

  # Terrain decoration on plain land: a hash sprinkles trees and hills.
  defp deco(%{type: :land, estate: nil, capital: -1} = f) do
    case rem(:erlang.phash2({f.x, f.y, :deco}), 100) do
      r when r < 14 -> :trees
      r when r < 22 -> :hill
      _ -> nil
    end
  end

  defp deco(_), do: nil

  # Two small wave strokes; the CSS animation pulses their opacity.
  defp wave_path(cx, cy) do
    "M #{cx - 12} #{cy - 4} q 5 -4 10 0 M #{cx + 1} #{cy + 7} q 5 -4 10 0"
  end

  attr :hx, :map, required: true

  defp terrain(assigns) do
    ~H"""
    <g style="pointer-events:none">
      <%= if @hx.deco == :trees do %>
        <line
          x1={@hx.cx - 7}
          y1={@hx.cy - 3}
          x2={@hx.cx - 7}
          y2={@hx.cy - 8}
          stroke="#6b5334"
          stroke-width="1.6"
        />
        <circle cx={@hx.cx - 7} cy={@hx.cy - 10} r="4" fill="#4a7c43" />
        <line
          x1={@hx.cx + 1}
          y1={@hx.cy + 3}
          x2={@hx.cx + 1}
          y2={@hx.cy - 2}
          stroke="#6b5334"
          stroke-width="1.4"
        />
        <circle cx={@hx.cx + 1} cy={@hx.cy - 4} r="3.2" fill="#3e6b3a" />
      <% else %>
        <path
          d={"M #{@hx.cx - 12} #{@hx.cy + 2} q 6 -9 12 0 Z"}
          fill="#00000018"
        />
        <path
          d={"M #{@hx.cx - 2} #{@hx.cy + 5} q 5 -7 10 0 Z"}
          fill="#00000012"
        />
      <% end %>
    </g>
    """
  end

  # --- settlement icon: castle for towns/capitals, dock for ports ---

  defp settlement(assigns) do
    ~H"""
    <g style="pointer-events:none">
      <ellipse cx={@hx.cx} cy={@hx.cy + 7} rx="12" ry="3.5" fill="#00000030" />
      <%= if @hx.estate == :port do %>
        <rect
          x={@hx.cx - 9}
          y={@hx.cy - 3}
          width="18"
          height="8"
          rx="1.5"
          fill="#7c6f5a"
          stroke="#3d3728"
          stroke-width="1"
        />
        <line
          x1={@hx.cx}
          y1={@hx.cy - 10}
          x2={@hx.cx}
          y2={@hx.cy - 3}
          stroke="#3d3728"
          stroke-width="1.5"
        />
        <path
          d={"M #{@hx.cx} #{@hx.cy - 10} L #{@hx.cx + 7} #{@hx.cy - 7} L #{@hx.cx} #{@hx.cy - 4} Z"}
          fill={sail_color(@hx)}
        />
      <% else %>
        <rect
          x={@hx.cx - 8}
          y={@hx.cy - 6}
          width="16"
          height="11"
          rx="1"
          fill="#cfc7b4"
          stroke="#4a4438"
          stroke-width="1.2"
        />
        <rect
          x={@hx.cx - 10}
          y={@hx.cy - 10}
          width="4.5"
          height="6"
          fill="#cfc7b4"
          stroke="#4a4438"
          stroke-width="1"
        />
        <rect
          x={@hx.cx + 5.5}
          y={@hx.cy - 10}
          width="4.5"
          height="6"
          fill="#cfc7b4"
          stroke="#4a4438"
          stroke-width="1"
        />
        <rect x={@hx.cx - 2} y={@hx.cy - 1} width="4" height="6" fill="#5b5344" />
        <%= if @hx.capital >= 0 do %>
          <line
            x1={@hx.cx}
            y1={@hx.cy - 16}
            x2={@hx.cx}
            y2={@hx.cy - 8}
            stroke="#3d3728"
            stroke-width="1.4"
          />
          <path
            d={"M #{@hx.cx} #{@hx.cy - 16} L #{@hx.cx + 9} #{@hx.cy - 13} L #{@hx.cx} #{@hx.cy - 10} Z"}
            fill={faction(@hx.capital).color}
            stroke="#0006"
            stroke-width="0.5"
          />
        <% end %>
      <% end %>
    </g>
    """
  end

  defp sail_color(%{party: -1}), do: "#9aa0a6"
  defp sail_color(%{party: p}), do: faction(p).color

  # --- army token: shield with count, morale pip below ---

  defp army_token(assigns) do
    assigns = assign(assigns, chips: div(max(assigns.hx.army.count - 1, 0), 33))

    ~H"""
    <g
      style="pointer-events:none"
      opacity={if @hx.army.moved and @hx.army.party == @viewer, do: "0.55", else: "1"}
    >
      <ellipse cx={@hx.cx} cy={@hx.cy + 17} rx="10.5" ry="3.2" fill="#00000038" />
      <circle
        :for={i <- @chips..1//-1}
        cx={@hx.cx}
        cy={@hx.cy + 6 + i * 2.5}
        r="11"
        fill={faction(@hx.army.party).dark}
        stroke="#14200f"
        stroke-width="1.2"
      />
      <circle
        cx={@hx.cx}
        cy={@hx.cy + 6}
        r="11"
        fill={faction(@hx.army.party).color}
        stroke="#14200f"
        stroke-width="1.6"
      />
      <text
        x={@hx.cx}
        y={@hx.cy + 10}
        text-anchor="middle"
        font-size="11"
        font-weight="800"
        fill="#fff"
        stroke="#0008"
        stroke-width="0.5"
        paint-order="stroke"
      >
        {@hx.army.count}
      </text>
      <text
        x={@hx.cx}
        y={@hx.cy + 19.5}
        text-anchor="middle"
        font-size="6.5"
        font-weight="700"
        fill="#ffea9c"
        stroke="#0009"
        stroke-width="0.4"
        paint-order="stroke"
      >
        ★{@hx.army.morale}
      </text>
    </g>
    """
  end
end
