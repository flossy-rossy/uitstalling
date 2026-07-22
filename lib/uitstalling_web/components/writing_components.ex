defmodule UitstallingWeb.WritingComponents do
  @moduledoc """
  Shared look-up tables and small components for the writing surfaces: page
  palettes per writing theme, the font utility classes, element-type colors,
  and the themed element-type dropdown. Literal Tailwind class strings, same
  reason as `DeckComponents` — Tailwind needs complete strings at build time.
  """

  use Phoenix.Component

  # Reading-first palettes. paper is the default: a warm, faintly yellow
  # page with near-black ink — the e-reader look. plain is pure print.
  # The deck palettes come along re-tuned for long-form text.
  @page %{
    "paper" => %{
      bg: "bg-[#f8f3e7]",
      ink: "text-stone-900",
      muted: "text-stone-500",
      faint: "text-stone-400",
      accent: "text-amber-800",
      rule: "border-stone-900/10",
      card: "bg-stone-900/[0.04]",
      hover: "hover:bg-stone-900/5",
      light: true
    },
    "plain" => %{
      bg: "bg-white",
      ink: "text-zinc-950",
      muted: "text-zinc-500",
      faint: "text-zinc-400",
      accent: "text-zinc-900",
      rule: "border-zinc-900/10",
      card: "bg-zinc-900/[0.04]",
      hover: "hover:bg-zinc-900/5",
      light: true
    },
    "noir" => %{
      bg: "bg-zinc-950",
      ink: "text-zinc-100",
      muted: "text-zinc-400",
      faint: "text-zinc-500",
      accent: "text-amber-400",
      rule: "border-white/10",
      card: "bg-white/[0.04]",
      hover: "hover:bg-white/5",
      light: false
    },
    "midnight" => %{
      bg: "bg-slate-950",
      ink: "text-slate-100",
      muted: "text-slate-400",
      faint: "text-slate-500",
      accent: "text-cyan-400",
      rule: "border-white/10",
      card: "bg-white/[0.04]",
      hover: "hover:bg-white/5",
      light: false
    },
    "blush" => %{
      bg: "bg-rose-50",
      ink: "text-zinc-900",
      muted: "text-zinc-500",
      faint: "text-zinc-400",
      accent: "text-rose-700",
      rule: "border-zinc-900/10",
      card: "bg-zinc-900/[0.04]",
      hover: "hover:bg-zinc-900/5",
      light: true
    },
    "pistachio" => %{
      bg: "bg-lime-50",
      ink: "text-zinc-900",
      muted: "text-zinc-500",
      faint: "text-zinc-400",
      accent: "text-emerald-700",
      rule: "border-zinc-900/10",
      card: "bg-zinc-900/[0.04]",
      hover: "hover:bg-zinc-900/5",
      light: true
    },
    "powder" => %{
      bg: "bg-sky-50",
      ink: "text-zinc-900",
      muted: "text-zinc-500",
      faint: "text-zinc-400",
      accent: "text-sky-700",
      rule: "border-zinc-900/10",
      card: "bg-zinc-900/[0.04]",
      hover: "hover:bg-zinc-900/5",
      light: true
    }
  }

  # Swatch chips for the theme picker — the page tone at a glance.
  @swatch %{
    "paper" => "bg-[#f8f3e7] ring-stone-400",
    "plain" => "bg-white ring-zinc-400",
    "noir" => "bg-zinc-950 ring-amber-400",
    "midnight" => "bg-slate-950 ring-cyan-400",
    "blush" => "bg-rose-100 ring-rose-400",
    "pistachio" => "bg-lime-100 ring-emerald-400",
    "powder" => "bg-sky-100 ring-sky-400"
  }

  # Plan-element colors: one hue per type, as chip classes (light/dark page
  # variants) and as hex for the SVG story map. Chapters get the neutral.
  @element_colors %{
    "character" => %{
      light: "text-amber-700 ring-amber-600/40",
      dark: "text-amber-400 ring-amber-400/40",
      hex: "#f59e0b"
    },
    "family" => %{
      light: "text-fuchsia-700 ring-fuchsia-600/40",
      dark: "text-fuchsia-400 ring-fuchsia-400/40",
      hex: "#d946ef"
    },
    "faction" => %{
      light: "text-rose-700 ring-rose-600/40",
      dark: "text-rose-400 ring-rose-400/40",
      hex: "#f43f5e"
    },
    "nation" => %{
      light: "text-red-700 ring-red-600/40",
      dark: "text-red-400 ring-red-400/40",
      hex: "#dc2626"
    },
    "location" => %{
      light: "text-emerald-700 ring-emerald-600/40",
      dark: "text-emerald-400 ring-emerald-400/40",
      hex: "#10b981"
    },
    "theme" => %{
      light: "text-violet-700 ring-violet-600/40",
      dark: "text-violet-400 ring-violet-400/40",
      hex: "#8b5cf6"
    },
    "object" => %{
      light: "text-sky-700 ring-sky-600/40",
      dark: "text-sky-400 ring-sky-400/40",
      hex: "#0ea5e9"
    },
    "arc" => %{
      light: "text-indigo-700 ring-indigo-600/40",
      dark: "text-indigo-400 ring-indigo-400/40",
      hex: "#6366f1"
    },
    "chapter" => %{
      light: "text-stone-600 ring-stone-500/40",
      dark: "text-stone-400 ring-stone-400/40",
      hex: "#a8a29e"
    },
    "planning" => %{
      light: "text-slate-600 ring-slate-500/40",
      dark: "text-slate-400 ring-slate-400/40",
      hex: "#94a3b8"
    }
  }

  @doc "Chip classes for an element type (or doc kind) on a light/dark page."
  def element_chip(type, light?) do
    colors = @element_colors[type] || @element_colors["planning"]
    if light?, do: colors.light, else: colors.dark
  end

  @doc "The story-map node color for an element type (or doc kind)."
  def element_hex(type), do: (@element_colors[type] || @element_colors["planning"]).hex

  @doc "Ink/edge colors the SVG story map draws chrome with, per page theme."
  def map_colors(theme) do
    if page_theme(theme).light,
      do: %{ink: "#1c1917", edge: "rgba(28, 25, 23, 0.18)"},
      else: %{ink: "#f4f4f5", edge: "rgba(244, 244, 245, 0.18)"}
  end

  @font_class %{
    "literata" => "font-literata",
    "garamond" => "font-garamond",
    "source_serif" => "font-source-serif",
    "georgia" => "font-georgia"
  }

  @font_label %{
    "literata" => "Literata",
    "garamond" => "EB Garamond",
    "source_serif" => "Source Serif",
    "georgia" => "Georgia"
  }

  def page_theme(theme), do: @page[theme] || @page["paper"]
  def swatch(theme), do: @swatch[theme] || @swatch["paper"]
  def font_class(font), do: @font_class[font] || @font_class["literata"]
  def font_label(font), do: @font_label[font] || font

  @doc """
  Element-type picker in the page's own clothes — never the browser-native
  `<select>`. Stateless: the view owns `picked`/`open` and handles the
  `toggle`/`pick` events (pick sends `phx-value-type`). Clicking away while
  open fires `toggle` (which closes it).
  """
  attr :picked, :string, required: true
  attr :open, :boolean, required: true
  attr :toggle, :string, required: true
  attr :pick, :string, required: true
  attr :palette, :map, required: true

  def type_dropdown(assigns) do
    ~H"""
    <div class="relative shrink-0" phx-click-away={@open && @toggle}>
      <button
        type="button"
        phx-click={@toggle}
        class={[
          "flex items-center gap-1.5 rounded border px-2 py-1.5 font-mono text-[10px] uppercase tracking-wider",
          @palette.rule,
          @palette.hover
        ]}
      >
        <span class="inline-block w-2 h-2 rounded-full" style={"background: #{element_hex(@picked)}"}></span>
        {@picked} <span class="opacity-50">▾</span>
      </button>

      <div
        :if={@open}
        class={[
          "absolute left-0 top-9 z-40 w-36 rounded-lg border shadow-lg p-1",
          @palette.bg,
          @palette.rule
        ]}
      >
        <button
          :for={type <- Uitstalling.Writing.element_types()}
          type="button"
          phx-click={@pick}
          phx-value-type={type}
          class={[
            "flex w-full items-center gap-2 text-left px-2.5 py-1.5 rounded font-mono text-[10px] uppercase tracking-wider",
            @palette.hover,
            type == @picked && "font-bold"
          ]}
        >
          <span class="inline-block w-2 h-2 rounded-full" style={"background: #{element_hex(type)}"}></span>
          {type}
        </button>
      </div>
    </div>
    """
  end
end
