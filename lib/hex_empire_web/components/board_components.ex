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

  @doc "SVG viewBox width for the 20x11 board."
  def viewbox_w, do: 19 * @xstep + @fw

  @doc "SVG viewBox height for the 20x11 board."
  def viewbox_h, do: 11 * @fh + @fh / 2

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

      %{
        key: key,
        cx: cx,
        cy: cy,
        points: hex_points(cx, cy),
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
      <g :for={hx <- @hexes}>
        <polygon
          points={hx.points}
          fill={land_fill(hx)}
          stroke={if hx.selected, do: "#ffe000", else: "#22301c"}
          stroke-width={if hx.selected, do: "3.5", else: "1"}
          class="he-hex"
          phx-click="hex"
          phx-value-k={hx.key}
        />
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
          style="pointer-events:none"
        />
        <.settlement :if={hx.estate != nil} hx={hx} />
        <.army_token :if={hx.army != nil} hx={hx} viewer={@viewer} />
      </g>
    </svg>
    """
  end

  @doc "Faction metadata by party id."
  def faction(party), do: Enum.at(Engine.factions(), party)

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

  defp land_fill(%{type: :water}), do: "#2e6da8"
  defp land_fill(%{party: -1}), do: "#d8cfa8"

  defp land_fill(%{party: p}) do
    %{
      0 => "#e8b3b3",
      1 => "#e3b3e3",
      2 => "#aed2ea",
      3 => "#b6e0b6"
    }[p]
  end

  # --- settlement icon: castle for towns/capitals, dock for ports ---

  defp settlement(assigns) do
    ~H"""
    <g style="pointer-events:none">
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
    ~H"""
    <g
      style="pointer-events:none"
      opacity={if @hx.army.moved and @hx.army.party == @viewer, do: "0.55", else: "1"}
    >
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
