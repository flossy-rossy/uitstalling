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

  # Colour SLOTS — a fixed palette keyed by name (not by element type), each
  # a light/dark chip class pair plus a hex for the SVG story map. Element
  # types (built-in and custom) map to a slot via the per-user registry from
  # `Uitstalling.Writing`; keeping the class strings literal here is what lets
  # a custom type wear a real colour without breaking Tailwind's build.
  @colors %{
    "amber" => %{
      light: "text-amber-700 ring-amber-600/40",
      dark: "text-amber-400 ring-amber-400/40",
      hex: "#f59e0b"
    },
    "emerald" => %{
      light: "text-emerald-700 ring-emerald-600/40",
      dark: "text-emerald-400 ring-emerald-400/40",
      hex: "#10b981"
    },
    "sky" => %{
      light: "text-sky-700 ring-sky-600/40",
      dark: "text-sky-400 ring-sky-400/40",
      hex: "#0ea5e9"
    },
    "fuchsia" => %{
      light: "text-fuchsia-700 ring-fuchsia-600/40",
      dark: "text-fuchsia-400 ring-fuchsia-400/40",
      hex: "#d946ef"
    },
    "rose" => %{
      light: "text-rose-700 ring-rose-600/40",
      dark: "text-rose-400 ring-rose-400/40",
      hex: "#f43f5e"
    },
    "red" => %{
      light: "text-red-700 ring-red-600/40",
      dark: "text-red-400 ring-red-400/40",
      hex: "#dc2626"
    },
    "violet" => %{
      light: "text-violet-700 ring-violet-600/40",
      dark: "text-violet-400 ring-violet-400/40",
      hex: "#8b5cf6"
    },
    "indigo" => %{
      light: "text-indigo-700 ring-indigo-600/40",
      dark: "text-indigo-400 ring-indigo-400/40",
      hex: "#6366f1"
    },
    "orange" => %{
      light: "text-orange-700 ring-orange-600/40",
      dark: "text-orange-400 ring-orange-400/40",
      hex: "#f97316"
    },
    "teal" => %{
      light: "text-teal-700 ring-teal-600/40",
      dark: "text-teal-400 ring-teal-400/40",
      hex: "#14b8a6"
    },
    "cyan" => %{
      light: "text-cyan-700 ring-cyan-600/40",
      dark: "text-cyan-400 ring-cyan-400/40",
      hex: "#06b6d4"
    },
    "lime" => %{
      light: "text-lime-700 ring-lime-600/40",
      dark: "text-lime-400 ring-lime-400/40",
      hex: "#65a30d"
    },
    "stone" => %{
      light: "text-stone-600 ring-stone-500/40",
      dark: "text-stone-400 ring-stone-400/40",
      hex: "#a8a29e"
    },
    "slate" => %{
      light: "text-slate-600 ring-slate-500/40",
      dark: "text-slate-400 ring-slate-400/40",
      hex: "#94a3b8"
    }
  }

  @fallback_slot "slate"

  @doc "Chip classes for a colour slot on a light/dark page."
  def chip_class(color, light?) do
    slot = @colors[color] || @colors[@fallback_slot]
    if light?, do: slot.light, else: slot.dark
  end

  @doc "Hex for a colour slot (SVG story map)."
  def color_hex(color), do: (@colors[color] || @colors[@fallback_slot]).hex

  @doc "Chip classes for a doc's element type/kind, resolved via the user registry."
  def element_chip(registry, type, light?), do: chip_class(registry_color(registry, type), light?)

  @doc "Hex for a doc's element type/kind, resolved via the user registry."
  def element_hex(registry, type), do: color_hex(registry_color(registry, type))

  @doc "The colour slot a type maps to in this user's registry (fallback slate)."
  def registry_color(registry, type) do
    case registry[type] do
      %{color: color} -> color
      _ -> @fallback_slot
    end
  end

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
  A centered spinner in the page's ink — shown while a writing surface streams
  its decrypted content in from the ProjectServer (the decrypt work is what's
  slow on a shared CPU, so every writing page loads its frame first, content
  second).
  """
  attr :palette, :map, required: true
  attr :label, :string, default: "loading…"

  def loading(assigns) do
    ~H"""
    <div class="min-h-[60dvh] flex flex-col items-center justify-center gap-4">
      <span class={[
        "inline-block w-8 h-8 rounded-full border-2 border-t-transparent animate-spin",
        @palette.faint
      ]}></span>
      <p class={["font-mono text-xs tracking-wider", @palette.faint]}>{@label}</p>
    </div>
    """
  end

  @doc """
  Element-type picker in the page's own clothes — never the browser-native
  `<select>`. Stateless: the view owns `picked`/`open` and passes the user's
  active `types` (`[%{key, label, color}]`); it handles the `toggle`/`pick`
  events (pick sends `phx-value-type` = the key). Clicking away while open
  fires `toggle`.
  """
  attr :types, :list, required: true
  attr :picked, :string, required: true
  attr :open, :boolean, required: true
  attr :toggle, :string, required: true
  attr :pick, :string, required: true
  attr :palette, :map, required: true

  def type_dropdown(assigns) do
    assigns = assign(assigns, :picked_type, Enum.find(assigns.types, &(&1.key == assigns.picked)))

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
        <span
          :if={@picked_type}
          class="inline-block w-2 h-2 rounded-full"
          style={"background: #{color_hex(@picked_type.color)}"}
        ></span>
        {(@picked_type && @picked_type.label) || @picked} <span class="opacity-50">▾</span>
      </button>

      <div
        :if={@open}
        class={[
          "absolute left-0 top-9 z-40 w-40 rounded-lg border shadow-lg p-1 max-h-72 overflow-y-auto",
          @palette.bg,
          @palette.rule
        ]}
      >
        <button
          :for={type <- @types}
          type="button"
          phx-click={@pick}
          phx-value-type={type.key}
          class={[
            "flex w-full items-center gap-2 text-left px-2.5 py-1.5 rounded font-mono text-[10px] uppercase tracking-wider",
            @palette.hover,
            type.key == @picked && "font-bold"
          ]}
        >
          <span
            class="inline-block w-2 h-2 rounded-full"
            style={"background: #{color_hex(type.color)}"}
          ></span>
          {type.label}
        </button>
      </div>
    </div>
    """
  end
end
