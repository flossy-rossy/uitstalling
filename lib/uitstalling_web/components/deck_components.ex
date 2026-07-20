defmodule UitstallingWeb.DeckComponents do
  @moduledoc """
  Renders a `Uitstalling.Decks.Deck` — the only path from AST to markup.

  Every text field goes through `inline/1`, which parses the mini inline
  markup (`**strong**`, `==accent==`, `~~strike~~`, `` `code` ``, newlines)
  and lets HEEx escape each run — deck JSON can never inject HTML.

  All colour comes from the literal class lookup tables below (Tailwind needs
  complete class strings at build time), so a deck can only pick from the
  palette, never supply arbitrary styling. Layouts here were extracted from
  the hand-written WebAuthn talk in `PresentationLive`.
  """

  use Phoenix.Component

  # ----- Theme lookups ------------------------------------------------------

  @accent_text %{
    "amber" => "text-amber-400",
    "sky" => "text-sky-400",
    "emerald" => "text-emerald-400",
    "rose" => "text-rose-400",
    "violet" => "text-violet-400",
    "cyan" => "text-cyan-400"
  }

  @accent_text_deep %{
    "amber" => "text-amber-600",
    "sky" => "text-sky-600",
    "emerald" => "text-emerald-600",
    "rose" => "text-rose-600",
    "violet" => "text-violet-600",
    "cyan" => "text-cyan-600"
  }

  @accent_bg %{
    "amber" => "bg-amber-500",
    "sky" => "bg-sky-500",
    "emerald" => "bg-emerald-500",
    "rose" => "bg-rose-500",
    "violet" => "bg-violet-500",
    "cyan" => "bg-cyan-500"
  }

  @flow_colors %{
    "sky" => {"ring-sky-700 bg-sky-950/40", "text-sky-300"},
    "emerald" => {"ring-emerald-700 bg-emerald-950/40", "text-emerald-300"},
    "amber" => {"ring-amber-700 bg-amber-950/40", "text-amber-300"},
    "rose" => {"ring-rose-700 bg-rose-950/40", "text-rose-300"},
    "zinc" => {"ring-zinc-700 bg-zinc-900", "text-zinc-300"}
  }

  # Cell tints per base: -400s carry on dark; on pastel they wash out
  # (amber-400 reads as illegible yellow), so light themes go -700.
  @tints %{
    "ok" => "text-emerald-400",
    "warn" => "text-amber-400",
    "bad" => "text-red-400",
    "none" => nil
  }

  @tints_light %{
    "ok" => "text-emerald-700",
    "warn" => "text-amber-700",
    "bad" => "text-red-700",
    "none" => nil
  }

  # Deck-level themes: the "default" tone's base colours. "noir" is the house
  # black/amber look; "midnight" is a deep navy base built for the cyan
  # accent. The pastel trio are LIGHT bases (light: true): dark body text,
  # and accents switch to their -600 "deep" variants for contrast.
  @theme_base %{
    "noir" => %{
      bg: "bg-zinc-950 text-zinc-100",
      muted: "text-zinc-400",
      faint: "text-zinc-500",
      light: false
    },
    "midnight" => %{
      bg: "bg-[#0a1128] text-slate-100",
      muted: "text-slate-400",
      faint: "text-slate-500",
      light: false
    },
    "blush" => %{
      bg: "bg-[#ffcbe1] text-zinc-900",
      muted: "text-zinc-700",
      faint: "text-zinc-500",
      light: true
    },
    "pistachio" => %{
      bg: "bg-[#d6e5bd] text-zinc-900",
      muted: "text-zinc-700",
      faint: "text-zinc-500",
      light: true
    },
    "powder" => %{
      bg: "bg-[#bcd8ec] text-zinc-900",
      muted: "text-zinc-700",
      faint: "text-zinc-500",
      light: true
    }
  }

  defp theme_base(theme), do: @theme_base[theme] || @theme_base["noir"]

  defp light_theme?(theme), do: theme_base(theme).light

  defp tone_bg("default", theme, _accent), do: theme_base(theme).bg
  defp tone_bg("accent", _theme, accent), do: "#{@accent_bg[accent]} text-zinc-950"
  defp tone_bg("danger", _theme, _accent), do: "bg-red-950 text-red-50"
  defp tone_bg("light", _theme, _accent), do: "bg-zinc-100 text-zinc-900"

  defp muted("default", theme), do: theme_base(theme).muted
  defp muted("accent", _theme), do: "text-zinc-800"
  defp muted("danger", _theme), do: "text-red-100"
  defp muted("light", _theme), do: "text-zinc-600"

  defp faint("default", theme), do: theme_base(theme).faint
  defp faint("accent", _theme), do: "text-zinc-700"
  defp faint("danger", _theme), do: "text-red-300"
  defp faint("light", _theme), do: "text-zinc-500"

  # The default tone inherits the theme's base, so light themes need the
  # deep accent there too — a -400 accent vanishes on pastel.
  defp kicker_class("default", theme, accent) do
    if light_theme?(theme), do: @accent_text_deep[accent], else: @accent_text[accent]
  end

  defp kicker_class("accent", _theme, _accent), do: "text-zinc-700"
  defp kicker_class("danger", _theme, _accent), do: "text-red-300"
  defp kicker_class("light", _theme, accent), do: @accent_text_deep[accent]

  # Class for `==accent==` inline marks, adapted so the mark stays visible
  # on every tone (accent-on-accent would vanish).
  defp accent_mark("accent", _theme, _accent), do: "text-zinc-900 font-bold"
  defp accent_mark("light", _theme, accent), do: "#{@accent_text_deep[accent]} font-semibold"

  defp accent_mark("default", theme, accent) do
    if light_theme?(theme),
      do: "#{@accent_text_deep[accent]} font-semibold",
      else: @accent_text[accent]
  end

  defp accent_mark(_tone, _theme, accent), do: @accent_text[accent]

  # ----- Size lookups ---------------------------------------------------------
  #
  # The per-slide `size` knob ("sm" | "md" | "lg"). Full literal class strings
  # per step, same Tailwind constraint as the colour tables.

  defp hero_heading("sm"), do: "text-5xl sm:text-6xl"
  defp hero_heading("md"), do: "text-6xl sm:text-7xl"
  defp hero_heading("lg"), do: "text-7xl sm:text-8xl"

  defp section_heading("sm"), do: "text-3xl sm:text-4xl"
  defp section_heading("md"), do: "text-4xl sm:text-5xl"
  defp section_heading("lg"), do: "text-5xl sm:text-6xl"

  defp statement_body("sm"), do: "text-2xl sm:text-3xl"
  defp statement_body("md"), do: "text-3xl sm:text-4xl"
  defp statement_body("lg"), do: "text-4xl sm:text-5xl"

  defp code_size("sm"), do: "text-xl sm:text-2xl"
  defp code_size("md"), do: "text-2xl sm:text-4xl"
  defp code_size("lg"), do: "text-3xl sm:text-5xl"

  defp subheading_size("sm"), do: "text-xl"
  defp subheading_size("md"), do: "text-2xl"
  defp subheading_size("lg"), do: "text-3xl"

  # ----- Slide wrapper + dispatch -------------------------------------------

  attr :deck, Uitstalling.Decks.Deck, required: true
  attr :slide, Uitstalling.Decks.Slide, required: true
  attr :index, :integer, required: true
  attr :edit, :boolean, default: false
  # Print (PDF) rendering: live-only content must degrade to something a
  # page can hold — video becomes a still placeholder card, images load
  # eagerly (Chrome's print skips lazy offscreen images).
  attr :print, :boolean, default: false
  # Pending agent work as a list of {slide_id, block_path | nil} — a nil block
  # means the whole slide is being regenerated.
  attr :pending, :list, default: []

  def slide(assigns) do
    %{slide: slide, deck: deck, pending: pending} = assigns
    tone = slide.tone
    accent = deck.accent
    theme = deck.theme

    busy = {slide.id, nil} in pending

    busy_blocks =
      for {id, block} <- pending, id == slide.id, block != nil, into: MapSet.new(), do: block

    assigns =
      assign(assigns,
        f: slide.fields,
        tone: tone,
        sz: slide.size,
        busy: busy,
        busy_blocks: busy_blocks,
        bg: tone_bg(tone, theme, accent),
        light: light_theme?(theme),
        muted: muted(tone, theme),
        faint: faint(tone, theme),
        kicker_class: kicker_class(tone, theme, accent),
        accent_class: accent_mark(tone, theme, accent),
        accent_text: @accent_text[accent]
      )

    ~H"""
    <section
      id={"slide-#{@index}"}
      data-slide-id={@slide.id}
      class={[
        "relative min-h-screen w-full flex flex-col justify-center px-8 sm:px-16 lg:px-32 py-24",
        @bg,
        @edit && "outline outline-1 -outline-offset-8 outline-dashed outline-zinc-400/60"
      ]}
    >
      <button
        :if={@edit and not @busy}
        phx-click="select_slide"
        phx-value-index={@index}
        class="absolute top-4 left-1/2 -translate-x-1/2 font-mono text-sm text-zinc-400 bg-zinc-900/90 ring-1 ring-zinc-700 rounded-full px-5 py-2.5 hover:text-(--ui-a4) hover:ring-(--ui-a5) transition"
      >
        ✎ tap any part to edit it · tap empty space for slide options
      </button>
      <div class={["max-w-5xl mx-auto w-full", @busy && "pointer-events-none opacity-60"]}>
        <.block
          :if={@slide.kicker}
          edit={@edit}
          index={@index}
          path="kicker"
          busy_blocks={@busy_blocks}
        >
          <p class={["font-mono text-sm mb-6 tracking-wider", @kicker_class]}>
            {@slide.kicker}
          </p>
        </.block>
        <.body
          slide={@slide}
          f={@f}
          tone={@tone}
          sz={@sz}
          edit={@edit}
          print={@print}
          light={@light}
          index={@index}
          busy_blocks={@busy_blocks}
          muted={@muted}
          faint={@faint}
          kicker_class={@kicker_class}
          accent_class={@accent_class}
          accent_text={@accent_text}
        />
        <.block
          :if={@f["image"] || MapSet.member?(@busy_blocks, "image")}
          edit={@edit}
          index={@index}
          path="image"
          busy_blocks={@busy_blocks}
        >
          <.asset_image image={@f["image"]} print={@print} />
        </.block>
        <.block
          :if={@slide.footnote}
          edit={@edit}
          index={@index}
          path="footnote"
          busy_blocks={@busy_blocks}
        >
          <p class={[
            "mt-16 text-xl leading-relaxed max-w-4xl",
            @muted,
            @slide.layout == "flow" && "mx-auto text-center italic"
          ]}>
            <.inline text={@slide.footnote} accent_class={@accent_class} />
          </p>
        </.block>
      </div>
      <.busy_overlay :if={@busy} />
    </section>
    """
  end

  # Wraps a logical block of the slide. In edit mode it becomes a click
  # target with a faint outline; while the agent is working on it, it shows
  # a "generating…" overlay and stops being interactable. Otherwise it
  # renders the content untouched.
  attr :edit, :boolean, required: true
  attr :index, :integer, required: true
  attr :path, :string, required: true
  attr :busy_blocks, :any, default: MapSet.new()
  slot :inner_block, required: true

  defp block(assigns) do
    assigns = assign(assigns, :busy, MapSet.member?(assigns.busy_blocks, assigns.path))

    ~H"""
    <%= if @edit or @busy do %>
      <div
        class={[
          "relative rounded-lg transition",
          @edit && !@busy &&
            "outline outline-1 outline-dashed outline-zinc-400/50 hover:outline-(--ui-a4)/80 hover:bg-zinc-400/10 cursor-pointer"
        ]}
        phx-click={@edit && !@busy && "select_block"}
        phx-value-index={@index}
        phx-value-block={@path}
        title={if(@edit and not @busy, do: "edit #{@path}")}
      >
        <div class={@busy && "pointer-events-none opacity-60"}>
          {render_slot(@inner_block)}
        </div>
        <.busy_overlay :if={@busy} />
      </div>
    <% else %>
      {render_slot(@inner_block)}
    <% end %>
    """
  end

  defp busy_overlay(assigns) do
    ~H"""
    <div class="absolute inset-0 z-20 flex items-center justify-center cursor-wait rounded-lg bg-zinc-950/60">
      <div class="flex items-center gap-3 font-mono text-sm text-(--ui-a4) bg-zinc-900/90 ring-1 ring-(--ui-a5)/40 rounded-full px-5 py-2.5">
        <span class="inline-block w-4 h-4 border-2 border-(--ui-a4) border-t-transparent rounded-full animate-spin"></span>
        generating…
      </div>
    </div>
    """
  end

  # ----- Layout bodies --------------------------------------------------------

  defp body(%{slide: %{layout: "title"}} = assigns) do
    ~H"""
    <.block edit={@edit} index={@index} busy_blocks={@busy_blocks} path="heading">
      <h1 class={[
        "font-bold leading-tight mb-12 max-w-full break-words text-balance",
        hero_heading(@sz)
      ]}>
        <.inline text={@f["heading"]} accent_class={@accent_class} />
      </h1>
    </.block>
    <.block
      :if={@f["subheading"]}
      edit={@edit}
      index={@index}
      busy_blocks={@busy_blocks}
      path="subheading"
    >
      <p class={["max-w-3xl leading-relaxed", subheading_size(@sz), @muted]}>
        <.inline text={@f["subheading"]} accent_class={@accent_class} />
      </p>
    </.block>
    """
  end

  defp body(%{slide: %{layout: "statement"}} = assigns) do
    ~H"""
    <.block :if={@f["heading"]} edit={@edit} index={@index} busy_blocks={@busy_blocks} path="heading">
      <h2 class={["font-bold mb-12 max-w-full break-words text-balance", section_heading(@sz)]}>
        <.inline text={@f["heading"]} accent_class={@accent_class} />
      </h2>
    </.block>
    <.block edit={@edit} index={@index} busy_blocks={@busy_blocks} path="body">
      <p class={["font-medium leading-snug max-w-4xl", statement_body(@sz)]}>
        <.inline text={@f["body"]} accent_class={@accent_class} />
      </p>
    </.block>
    """
  end

  defp body(%{slide: %{layout: "bullets"}} = assigns) do
    ~H"""
    <.block edit={@edit} index={@index} busy_blocks={@busy_blocks} path="heading">
      <h2 class={["font-bold mb-12 max-w-full break-words text-balance", section_heading(@sz)]}>
        <.inline text={@f["heading"]} accent_class={@accent_class} />
      </h2>
    </.block>
    <div class={[
      "grid gap-12 text-xl leading-relaxed",
      length(@f["columns"]) == 2 && "md:grid-cols-2"
    ]}>
      <.block
        :for={{col, ci} <- Enum.with_index(@f["columns"])}
        edit={@edit}
        busy_blocks={@busy_blocks}
        index={@index}
        path={"columns.#{ci}"}
      >
        <ul class={["space-y-4 list-disc list-inside", @muted]}>
          <li :for={item <- col}>
            <.inline text={item} accent_class={@accent_class} />
          </li>
        </ul>
      </.block>
    </div>
    """
  end

  defp body(%{slide: %{layout: "points"}} = assigns) do
    ~H"""
    <.block edit={@edit} index={@index} busy_blocks={@busy_blocks} path="heading">
      <h2 class={["font-bold mb-12 max-w-full break-words text-balance", section_heading(@sz)]}>
        <.inline text={@f["heading"]} accent_class={@accent_class} />
      </h2>
    </.block>
    <div class="grid md:grid-cols-2 gap-x-12 gap-y-10 text-lg leading-relaxed">
      <.block
        :for={{point, pi} <- Enum.with_index(@f["points"])}
        edit={@edit}
        busy_blocks={@busy_blocks}
        index={@index}
        path={"points.#{pi}"}
      >
        <div>
          <p class={["font-mono text-sm mb-2", @kicker_class]}>{point["label"]}</p>
          <p class={@muted}>
            <.inline text={point["body"]} accent_class={@accent_class} />
          </p>
        </div>
      </.block>
    </div>
    """
  end

  defp body(%{slide: %{layout: "flow"}} = assigns) do
    ~H"""
    <.block :if={@f["heading"]} edit={@edit} index={@index} busy_blocks={@busy_blocks} path="heading">
      <h2 class={[
        "font-bold mb-12 text-center max-w-full break-words text-balance",
        section_heading(@sz)
      ]}>
        <.inline text={@f["heading"]} accent_class={@accent_class} />
      </h2>
    </.block>
    <div class="max-w-xl mx-auto">
      <%= for {step, i} <- Enum.with_index(@f["steps"]) do %>
        <.block edit={@edit} index={@index} busy_blocks={@busy_blocks} path={"steps.#{i}"}>
          <.flow_step
            actor={step["actor"]}
            color={step["color"] || "zinc"}
            body={step["body"]}
            accent_class={@accent_class}
          />
        </.block>
        <.flow_arrow
          :if={i < length(@f["steps"]) - 1 or @f["terminal"]}
          label={step["arrow_label"]}
          label_class={@accent_text}
        />
      <% end %>
      <.block
        :if={@f["terminal"]}
        edit={@edit}
        index={@index}
        busy_blocks={@busy_blocks}
        path="terminal"
      >
        <div class="w-full px-6 py-5 rounded-lg bg-emerald-900/40 ring-1 ring-emerald-600 text-center">
          <p class="font-mono text-sm text-emerald-300">{@f["terminal"]}</p>
        </div>
      </.block>
    </div>
    """
  end

  defp body(%{slide: %{layout: "big_code"}} = assigns) do
    ~H"""
    <.block :if={@f["heading"]} edit={@edit} index={@index} busy_blocks={@busy_blocks} path="heading">
      <h2 class={["font-bold mb-12 max-w-full break-words text-balance", section_heading(@sz)]}>
        <.inline text={@f["heading"]} accent_class={@accent_class} />
      </h2>
    </.block>
    <.block edit={@edit} index={@index} busy_blocks={@busy_blocks} path="code">
      <div class="text-center">
        <%!-- phx-no-format: inside pre-wrap, template whitespace renders literally --%>
        <code
          class={[
            "font-mono bg-zinc-900 text-zinc-100 rounded-lg px-8 py-6 inline-block ring-1 ring-zinc-800 whitespace-pre-wrap text-left",
            code_size(@sz)
          ]}
          phx-no-format
        ><.inline text={@f["code"]} accent_class={@accent_class} /></code>
      </div>
    </.block>
    <.block :if={@f["body"]} edit={@edit} index={@index} busy_blocks={@busy_blocks} path="body">
      <p class={["mt-12 text-xl leading-relaxed max-w-3xl", @muted]}>
        <.inline text={@f["body"]} accent_class={@accent_class} />
      </p>
    </.block>
    """
  end

  defp body(%{slide: %{layout: "table"}} = assigns) do
    ~H"""
    <.block :if={@f["heading"]} edit={@edit} index={@index} busy_blocks={@busy_blocks} path="heading">
      <h2 class={["font-bold mb-12 max-w-full break-words text-balance", section_heading(@sz)]}>
        <.inline text={@f["heading"]} accent_class={@accent_class} />
      </h2>
    </.block>
    <%!-- Rows are direct click targets (block divs can't nest in <table>
         markup): the header row edits "columns", each body row "rows.N" --%>
    <div class="overflow-x-auto">
      <table class="w-full text-lg">
        <thead>
          <tr
            class={[
              "border-b border-zinc-700 font-mono text-sm text-left",
              @kicker_class,
              @edit &&
                "cursor-pointer outline outline-1 outline-dashed outline-zinc-400/50 hover:outline-(--ui-a4)/80"
            ]}
            phx-click={@edit && "select_block"}
            phx-value-index={@index}
            phx-value-block="columns"
            title={@edit && "edit columns"}
          >
            <th :for={col <- @f["columns"]} class="py-4 pr-6 font-normal">{col}</th>
          </tr>
        </thead>
        <tbody class={@muted}>
          <tr
            :for={{row, ri} <- Enum.with_index(@f["rows"])}
            class={[
              "border-b border-zinc-800",
              @edit &&
                "cursor-pointer outline outline-1 outline-dashed outline-zinc-400/50 hover:outline-(--ui-a4)/80"
            ]}
            phx-click={@edit && "select_block"}
            phx-value-index={@index}
            phx-value-block={"rows.#{ri}"}
            title={@edit && "edit this row"}
          >
            <td :for={cell <- row} class={["py-6 pr-6 align-top", cell_tint(cell, @light)]}>
              <.inline text={cell_text(cell)} accent_class={@accent_class} />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp body(%{slide: %{layout: "media"}} = assigns) do
    ~H"""
    <.block :if={@f["heading"]} edit={@edit} index={@index} busy_blocks={@busy_blocks} path="heading">
      <h2 class={["font-bold mb-8 max-w-full break-words text-balance", section_heading(@sz)]}>
        <.inline text={@f["heading"]} accent_class={@accent_class} />
      </h2>
    </.block>
    <.block edit={@edit} index={@index} busy_blocks={@busy_blocks} path="src">
      <div class="aspect-video bg-zinc-900 rounded-lg overflow-hidden ring-1 ring-zinc-800">
        <%= cond do %>
          <% not @print and @f["kind"] == "video" and @f["src"] -> %>
            <video src={@f["src"]} class="w-full h-full" controls preload="metadata"></video>
          <% @f["kind"] == "video" and @f["src"] -> %>
            <%!-- Print: a PDF can't carry the video, so hold its place with a
                 card that says where it lives --%>
            <div class="w-full h-full flex flex-col items-center justify-center gap-3 text-zinc-500">
              <svg
                class="w-12 h-12"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <circle cx="12" cy="12" r="9" />
                <path d="M10 8.5l6 3.5-6 3.5z" fill="currentColor" stroke="none" />
              </svg>
              <p class="font-mono text-xs">video — plays in the live presentation</p>
              <p class="font-mono text-[10px] text-zinc-600 max-w-md truncate px-4">{@f["src"]}</p>
            </div>
          <% @f["kind"] == "image" and @f["src"] -> %>
            <img src={@f["src"]} class="w-full h-full object-contain" alt={@f["caption"] || ""} />
          <% true -> %>
            <%!-- No image yet: clean placeholder from the caption, not a broken <img> --%>
            <div class="w-full h-full flex flex-col items-center justify-center gap-3 text-zinc-600">
              <svg
                class="w-12 h-12"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <rect x="3" y="4" width="18" height="16" rx="2" />
                <circle cx="8.5" cy="9.5" r="1.5" />
                <path d="M21 16l-5-5L5 20" />
              </svg>
              <p class="font-mono text-xs text-zinc-500 max-w-xs text-center px-4">
                {@f["caption"] || "image goes here"}
              </p>
            </div>
        <% end %>
      </div>
    </.block>
    <.block :if={@f["caption"]} edit={@edit} index={@index} busy_blocks={@busy_blocks} path="caption">
      <p class={["mt-6 text-sm font-mono", @faint]}>{@f["caption"]}</p>
    </.block>
    """
  end

  defp body(%{slide: %{layout: "faq"}} = assigns) do
    ~H"""
    <.block edit={@edit} index={@index} busy_blocks={@busy_blocks} path="heading">
      <h2 class={["font-bold mb-12 max-w-full break-words text-balance", section_heading(@sz)]}>
        <.inline text={@f["heading"] || "Q&A"} accent_class={@accent_class} />
      </h2>
    </.block>
    <div class="space-y-8 text-lg leading-relaxed">
      <.block
        :for={{item, qi} <- Enum.with_index(@f["items"])}
        edit={@edit}
        busy_blocks={@busy_blocks}
        index={@index}
        path={"items.#{qi}"}
      >
        <div>
          <p class={["font-semibold mb-2", @kicker_class]}>{item["q"]}</p>
          <p class={@muted}>
            <.inline text={item["a"]} accent_class={@accent_class} />
          </p>
        </div>
      </.block>
    </div>
    """
  end

  # ----- Image part -------------------------------------------------------------
  #
  # The app-managed image attached to any layout: an asset reference, never a
  # raw URL — the renderer builds the /a/:id path, so deck JSON can't point an
  # <img> anywhere else. "full" spans the content column in the 16:9 frame;
  # "side" (default) is a restrained inset.

  attr :image, :map, default: nil
  attr :print, :boolean, default: false

  # No image yet (generation in flight — the block's busy overlay sits on
  # top of this): an empty frame so the slide shows where it will land.
  defp asset_image(%{image: nil} = assigns) do
    ~H"""
    <div class="mt-12 max-w-md aspect-video rounded-lg ring-1 ring-zinc-800 bg-zinc-900 flex items-center justify-center">
      <p class="font-mono text-xs text-zinc-600">image on its way…</p>
    </div>
    """
  end

  defp asset_image(assigns) do
    assigns = assign(assigns, :crop_style, crop_style(assigns.image["crop"]))

    ~H"""
    <figure class={[
      "mt-12",
      if(@image["treatment"] == "full", do: "w-full", else: "max-w-md")
    ]}>
      <div class={[
        "rounded-lg overflow-hidden ring-1 ring-zinc-800 bg-zinc-900",
        (@image["treatment"] == "full" or @image["crop"]) && "aspect-video"
      ]}>
        <img
          src={"/a/#{@image["asset_id"]}"}
          alt={@image["alt"] || ""}
          loading={if @print, do: "eager", else: "lazy"}
          style={@crop_style}
          class={[
            "w-full",
            if(@image["crop"] || @image["treatment"] == "full",
              do: "h-full object-cover",
              else: "max-h-72 object-contain"
            )
          ]}
        />
      </div>
      <figcaption :if={@image["alt"]} class="mt-3 text-sm font-mono text-zinc-500">
        {@image["alt"]}
      </figcaption>
    </figure>
    """
  end

  # Pan/zoom crop from three validated numbers — the style string is built
  # HERE from bounded numerics, deck JSON never carries CSS.
  defp crop_style(%{"x" => x, "y" => y, "zoom" => zoom})
       when is_number(x) and is_number(y) and is_number(zoom) do
    "object-position: #{x}% #{y}%; transform: scale(#{zoom}); transform-origin: #{x}% #{y}%"
  end

  defp crop_style(_crop), do: nil

  # ----- Flow sub-components --------------------------------------------------

  attr :actor, :string, required: true
  attr :color, :string, default: "zinc"
  attr :body, :string, required: true
  attr :accent_class, :string, required: true

  defp flow_step(assigns) do
    {ring_bg, actor_text} = @flow_colors[assigns.color] || @flow_colors["zinc"]
    assigns = assign(assigns, ring_bg: ring_bg, actor_text: actor_text)

    ~H"""
    <div class={["w-full px-6 py-5 rounded-lg ring-1", @ring_bg]}>
      <p class={["font-mono text-xs mb-2 tracking-wider", @actor_text]}>{@actor}</p>
      <p class="text-base text-zinc-100 leading-relaxed">
        <.inline text={@body} accent_class={@accent_class} />
      </p>
    </div>
    """
  end

  attr :label, :string, default: nil
  attr :label_class, :string, required: true

  defp flow_arrow(assigns) do
    ~H"""
    <div class="flex flex-col items-center my-0.5">
      <div class="h-4 w-0.5 bg-zinc-700"></div>
      <span
        :if={@label}
        class={["font-mono text-[10px] italic px-2 py-0.5 bg-zinc-900 rounded my-0.5", @label_class]}
      >
        {@label}
      </span>
      <div :if={@label} class="h-4 w-0.5 bg-zinc-700"></div>
      <div class="w-0 h-0 border-l-[5px] border-r-[5px] border-t-[6px] border-transparent border-t-zinc-600">
      </div>
    </div>
    """
  end

  defp cell_text(cell) when is_binary(cell), do: cell
  defp cell_text(%{"text" => text}), do: text

  defp cell_tint(%{"tint" => tint}, light) do
    if light, do: @tints_light[tint], else: @tints[tint]
  end

  defp cell_tint(_cell, _light), do: nil

  # ----- Inline mini-markup -----------------------------------------------------
  #
  # The only rich text a deck can express. Parsed into typed runs and built
  # as explicit iodata: every run goes through `esc/1`, so none of this can
  # smuggle markup through. Deliberately NOT a HEEx template — templates get
  # reformatted, and stray template whitespace between runs renders literally
  # inside `whitespace-pre-wrap` contexts (and as odd mid-sentence gaps
  # elsewhere). Iodata is immune to the formatter.

  @inline_re ~r/(\*\*[^*]+\*\*|~~[^~]+~~|==[^=]+==|`[^`]+`|\n)/

  attr :text, :string, required: true
  attr :accent_class, :string, required: true

  def inline(assigns) do
    assigns = assign(assigns, :html, {:safe, build_inline(assigns.text, assigns.accent_class)})

    ~H"{@html}"
  end

  defp build_inline(text, accent_class) do
    @inline_re
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn
      "\n" ->
        "<br/>"

      "**" <> rest ->
        [~s(<strong class="font-semibold">), esc(trim_mark(rest, "*")), "</strong>"]

      "~~" <> rest ->
        [~s(<span class="line-through opacity-60">), esc(trim_mark(rest, "~")), "</span>"]

      "==" <> rest ->
        [~s(<span class="), esc(accent_class), ~s(">), esc(trim_mark(rest, "=")), "</span>"]

      "`" <> rest ->
        [
          ~s(<code class="font-mono bg-zinc-900 text-amber-300 px-2 py-0.5 rounded-md text-[0.85em]">),
          esc(trim_mark(rest, "`")),
          "</code>"
        ]

      plain ->
        esc(plain)
    end)
  end

  defp trim_mark(text, mark), do: String.trim_trailing(text, mark)

  defp esc(text), do: Phoenix.HTML.Engine.html_escape(text)
end
