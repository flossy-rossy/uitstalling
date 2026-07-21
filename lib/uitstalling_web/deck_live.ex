defmodule UitstallingWeb.DeckLive do
  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
  alias Uitstalling.Assets
  alias Uitstalling.Decks

  import UitstallingWeb.DeckComponents

  require Logger

  @undo_depth 20

  # Swatches for the in-place theme switcher. Literal classes (Tailwind),
  # same bases as Decks.themes() / DeckComponents.
  @theme_swatches [
    {"noir", "bg-zinc-950"},
    {"midnight", "bg-[#0a1128]"},
    {"blush", "bg-[#ffcbe1]"},
    {"pistachio", "bg-[#d6e5bd]"},
    {"powder", "bg-[#bcd8ec]"}
  ]

  # Optional scalar parts a slide of each layout may gain (beyond what the
  # validator requires). "kicker"/"footnote" are addable on every layout.
  @addable_scalars %{
    "title" => ~w(subheading),
    "statement" => ~w(heading),
    "bullets" => [],
    "points" => [],
    "flow" => ~w(heading terminal),
    "big_code" => ~w(heading body),
    "table" => ~w(heading),
    "media" => ~w(heading caption),
    "faq" => ~w(heading)
  }

  # The list key each layout can grow, with a human label.
  @addable_lists %{
    "bullets" => {"columns", "bullet column"},
    "points" => {"points", "point"},
    "flow" => {"steps", "step"},
    "table" => {"rows", "row"},
    "faq" => {"items", "question"}
  }

  @scalar_placeholders %{
    "kicker" => "§ NEW · SECTION",
    "footnote" => "A footnote…",
    "subheading" => "A supporting line…",
    "heading" => "New heading",
    "body" => "New text…",
    "terminal" => "✓ DONE",
    "caption" => "A caption…"
  }

  # Public slugged URL: /:user_slug/:deck_slug (deck_slug may be a raw id —
  # pre-slug links stay alive forever).
  def mount(%{"user_slug" => user_slug, "deck_slug" => deck_slug}, _session, socket) do
    with %{} = owner <- Accounts.get_user_by_slug(user_slug),
         deck_id when is_binary(deck_id) <- Decks.deck_id_for(owner.id, deck_slug) do
      mount_deck(deck_id, socket, "/#{user_slug}/#{deck_slug}")
    else
      _ -> {:ok, socket |> put_flash(:error, "No such presentation") |> redirect(to: ~p"/")}
    end
  end

  # Legacy id URL — every link shared before slugs existed.
  def mount(%{"id" => deck_id}, _session, socket) do
    mount_deck(deck_id, socket, "/deck/#{deck_id}")
  end

  defp mount_deck(deck_id, socket, base_path) do
    with true <- Decks.exists?(deck_id),
         {raw, rev} = Decks.checkout(deck_id),
         # Lenient on purpose: a stored deck can stop validating without
         # anyone editing it (e.g. a referenced asset was deleted). That must
         # degrade to a flash, not a 500 that bricks the deck.
         {:ok, deck} <- Decks.parse(raw) do
      # Presenting is public-by-link; only an authorized author who owns the
      # deck may edit.
      user = socket.assigns.current_user
      can_edit = Accounts.can_author?(user) and Decks.owned_by?(deck_id, user.id)

      socket =
        assign(socket,
          deck_id: deck_id,
          remote_path: base_path <> "/remote",
          topic: "deck:#{deck_id}",
          page_title: deck.title,
          raw: raw,
          # Optimistic-lock revision this session last saw — every commit
          # hands it to Decks.save/4 so a concurrent write surfaces instead
          # of being overwritten.
          rev: rev,
          deck: deck,
          index: 0,
          can_edit: can_edit,
          edit_mode: false,
          selected: nil,
          # Typed-but-unsaved editor state, keyed by input name. Editor
          # fields render from this first, so a :deck_updated broadcast
          # landing mid-edit can't reset what's been typed.
          edit_form: %{},
          regen: nil,
          pdf_modal: false,
          pdf_busy: false,
          pdf_error: nil,
          theme_panel: false,
          theme_swatches: @theme_swatches,
          undo: [],
          edit_error: nil,
          pending: [],
          failures: [],
          failures_since: DateTime.utc_now() |> DateTime.truncate(:second),
          dismissed_failures: MapSet.new()
        )

      socket =
        if can_edit do
          allow_upload(socket, :image,
            accept: Assets.accepted_extensions(),
            max_entries: 1,
            max_file_size: Assets.max_bytes()
          )
        else
          socket
        end

      socket =
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Uitstalling.PubSub, socket.assigns.topic)
          refresh_pending(socket)
        else
          socket
        end

      {:ok, socket}
    else
      false ->
        {:ok, socket |> put_flash(:error, "No such presentation") |> redirect(to: ~p"/")}

      {:error, errors} ->
        {:ok,
         socket
         |> put_flash(:error, "This presentation needs repair: #{hd(errors)}")
         |> redirect(to: ~p"/")}
    end
  end

  def render(assigns) do
    ~H"""
    <main id="deck" phx-hook=".DeckNav" data-ui-accent={@deck.accent || "amber"}>
      <%!-- Keyed by slide id: an insert/delete moves DOM nodes instead of
           rewriting every following slide in place — which also keeps the
           browser's scroll anchored to the slide you're actually on. --%>
      <.slide
        :for={{slide, i} <- Enum.with_index(@deck.slides)}
        :key={slide.id}
        deck={@deck}
        slide={slide}
        index={i}
        edit={@edit_mode}
        pending={pending_specs(@pending)}
      />

      <div class="fixed bottom-4 right-6 flex items-center gap-3">
        <button
          phx-click="open_pdf"
          disabled={@pdf_busy}
          class="font-mono text-xs text-zinc-400 bg-zinc-900/80 px-3 py-1.5 rounded ring-1 ring-zinc-700 hover:text-(--ui-a4) hover:ring-(--ui-a5) transition flex items-center gap-1.5 disabled:opacity-60"
          title="download this presentation as a PDF backup"
        >
          <span
            :if={@pdf_busy}
            class="inline-block w-3 h-3 border-2 border-(--ui-a4) border-t-transparent rounded-full animate-spin"
          ></span>
          <.icon :if={!@pdf_busy} name="hero-arrow-down-tray" class="w-3.5 h-3.5" />
          {if @pdf_busy, do: "preparing…", else: "pdf"}
        </button>
        <span
          :if={@pdf_error}
          class="font-mono text-xs bg-red-950/95 text-red-200 ring-1 ring-red-800 rounded px-3 py-1.5 flex items-center gap-2"
        >
          ⚠ {@pdf_error}
          <button phx-click="dismiss_pdf_error" class="text-red-400 hover:text-red-100">✕</button>
        </span>
        <.link
          navigate={@remote_path}
          class="font-mono text-xs text-zinc-400 bg-zinc-900/80 px-3 py-1.5 rounded ring-1 ring-zinc-700 hover:text-(--ui-a4) hover:ring-(--ui-a5) transition flex items-center gap-1.5"
          title="open the phone remote for this presentation"
        >
          <.icon name="hero-device-phone-mobile" class="w-3.5 h-3.5" /> remote
        </.link>
        <span class="font-mono text-xs text-zinc-400 bg-zinc-900/80 px-3 py-1.5 rounded">
          {@index + 1} / {length(@deck.slides)}
        </span>
        <%!-- 8stal footer mark — the viral loop: every presented deck shows it.
             8 = ∞ on its side; "stal" from uit-STAL-ling. Workshop freely. --%>
        <.link
          navigate={~p"/"}
          class="font-mono text-xs text-zinc-500 bg-zinc-900/80 px-3 py-1.5 rounded hover:text-(--ui-a4) transition"
          title="Made with UIT"
        >
          <span class="text-(--ui-a4) font-bold">8</span>stal
        </.link>
      </div>

      <div class="fixed bottom-4 left-6 flex items-center gap-2">
        <.link
          navigate={~p"/"}
          class="font-mono text-sm px-4 py-2 rounded-lg ring-1 bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-(--ui-a4) transition"
        >
          ← decks
        </.link>
        <button
          :if={@can_edit}
          phx-click="toggle_edit"
          class={[
            "font-mono text-sm px-4 py-2 rounded-lg ring-1 transition",
            if(@edit_mode,
              do: "bg-(--ui-a5) text-zinc-950 ring-(--ui-a4) font-bold",
              else: "bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-(--ui-a4)"
            )
          ]}
        >
          {if @edit_mode, do: "✓ done", else: "✎ edit"}
        </button>
        <span
          :if={@pending != []}
          class="font-mono text-xs text-(--ui-a4) bg-zinc-900/80 px-3 py-1.5 rounded flex items-center gap-2"
        >
          <span class="inline-block w-3 h-3 border-2 border-(--ui-a4) border-t-transparent rounded-full animate-spin"></span>
          {length(@pending)} generating
          <button
            :for={req <- @pending}
            :if={@can_edit}
            phx-click="cancel_request"
            phx-value-id={req["id"]}
            title={"cancel this #{request_label(req)}"}
            class="ml-1 px-2 py-0.5 rounded ring-1 ring-zinc-700 text-zinc-400 hover:text-red-400 hover:ring-red-700 transition"
          >
            ✕ {request_label(req)}
          </button>
        </span>
      </div>

      <%!-- Edit command rail — icon squares on the left so the bottom bar
           stays lean as edit tooling grows --%>
      <div
        :if={@can_edit and @edit_mode}
        class="fixed left-4 top-1/2 -translate-y-1/2 z-40 flex flex-col gap-2"
      >
        <button
          phx-click="open_theme"
          title="change theme"
          class="w-11 h-11 flex items-center justify-center rounded-lg ring-1 bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-(--ui-a4) hover:ring-(--ui-a5) transition"
        >
          <.icon name="hero-swatch" class="w-5 h-5" />
        </button>
        <button
          phx-click="open_regen"
          title="regenerate deck"
          class="w-11 h-11 flex items-center justify-center rounded-lg ring-1 bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-(--ui-a4) hover:ring-(--ui-a5) transition"
        >
          <.icon name="hero-arrow-path" class="w-5 h-5" />
        </button>
        <button
          :if={@undo != []}
          phx-click="undo"
          title={"undo (#{length(@undo)})"}
          class="w-11 h-11 flex items-center justify-center rounded-lg ring-1 bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-(--ui-a4) hover:ring-(--ui-a5) transition"
        >
          <.icon name="hero-arrow-uturn-left" class="w-5 h-5" />
        </button>
      </div>

      <div
        :if={@theme_panel}
        class="fixed inset-0 z-50 bg-zinc-950/80 flex items-center justify-center p-4 sm:p-6"
      >
        <div class="w-full max-w-md bg-zinc-900 ring-1 ring-zinc-700 rounded-xl p-6">
          <p class="font-mono text-(--ui-a4) text-xs tracking-wider mb-4">DECK THEME</p>
          <p class="text-zinc-400 text-sm mb-5">
            Restyles <strong class="text-zinc-200">every slide in the deck</strong>
            — content untouched, ↶ undo brings the old look back. For one
            slide's colour, use SLIDE TONE in that slide's options instead.
          </p>
          <div class="grid grid-cols-5 gap-3">
            <button
              :for={{id, swatch} <- @theme_swatches}
              phx-click="set_theme"
              phx-value-theme={id}
              class="flex flex-col items-center gap-1.5"
            >
              <span class={[
                "w-12 h-12 rounded-lg ring-2 transition",
                swatch,
                if((@deck.theme || "noir") == id,
                  do: "ring-(--ui-a4)",
                  else: "ring-zinc-700 hover:ring-zinc-500"
                )
              ]}></span>
              <span class="font-mono text-[10px] text-zinc-400">{id}</span>
            </button>
          </div>
          <div class="mt-6 flex justify-end">
            <button
              phx-click="close_theme"
              class="px-5 py-2.5 rounded-lg text-zinc-300 ring-1 ring-zinc-700 hover:text-zinc-100 hover:ring-zinc-500"
            >
              Close
            </button>
          </div>
        </div>
      </div>

      <div
        :if={@can_edit and @failures != []}
        class="fixed bottom-16 left-1/2 -translate-x-1/2 z-40 space-y-2 max-w-2xl"
      >
        <div
          :for={failure <- @failures}
          class="flex items-center gap-3 font-mono text-xs bg-red-950/95 text-red-200 ring-1 ring-red-800 rounded-lg px-4 py-2.5"
        >
          <span>
            ⚠ {request_label(failure)} failed: {String.slice(failure["error"] || "unknown", 0, 120)}
          </span>
          <button
            phx-click="dismiss_failure"
            phx-value-id={failure["id"]}
            class="text-red-400 hover:text-red-100 shrink-0"
          >
            ✕
          </button>
        </div>
      </div>

      <.options_panel
        :if={@selected}
        selected={@selected}
        slide={Enum.at(@deck.slides, @selected.index)}
        value={@selected.block && Decks.get_block(@raw, @selected.index, @selected.block)}
        edit_form={@edit_form}
        addable={addable_parts(@raw, @selected.index)}
        edit_error={@edit_error}
        uploads={assigns[:uploads]}
      />

      <.regen_panel :if={@regen} regen={@regen} />

      <div
        :if={@pdf_modal}
        class="fixed inset-0 z-50 bg-zinc-950/80 flex items-center justify-center p-4 sm:p-6"
      >
        <div class="w-full max-w-md bg-zinc-900 ring-1 ring-zinc-700 rounded-xl p-6">
          <p class="font-mono text-(--ui-a4) text-xs tracking-wider mb-4">DOWNLOAD AS PDF</p>
          <p class="text-zinc-300 text-sm leading-relaxed">
            This deck has video on it. A PDF can't play video, so those slides
            get a still placeholder card instead — everything else comes along
            as-is. (The phone remote is live-only too.)
          </p>
          <div class="mt-6 flex justify-end gap-3">
            <button
              phx-click="close_pdf"
              class="px-5 py-2.5 rounded-lg text-zinc-300 ring-1 ring-zinc-700 hover:text-zinc-100 hover:ring-zinc-500"
            >
              Cancel
            </button>
            <button
              phx-click="start_pdf"
              class="px-5 py-2.5 rounded-lg bg-(--ui-a5) hover:bg-(--ui-a4) text-zinc-950 font-semibold"
            >
              Download PDF
            </button>
          </div>
        </div>
      </div>

      <div
        :if={creating?(@pending)}
        class="fixed inset-0 z-[60] bg-zinc-950/95 flex items-center justify-center"
      >
        <div class="flex flex-col items-center gap-6 text-center px-8">
          <span class="inline-block w-12 h-12 border-4 border-(--ui-a4) border-t-transparent rounded-full animate-spin"></span>
          <p class="font-mono text-(--ui-a4) text-lg">generating your presentation…</p>
          <p class="text-zinc-500 text-sm max-w-sm">
            This page updates itself the moment it's ready — usually under a minute.
          </p>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DeckNav">
        export default {
          mounted() {
            this.onKey = (e) => {
              if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return
              if (["ArrowRight", "ArrowDown", "PageDown", " "].includes(e.key)) {
                e.preventDefault()
                this.pushEvent("nav", {dir: 1})
              } else if (["ArrowLeft", "ArrowUp", "PageUp"].includes(e.key)) {
                e.preventDefault()
                this.pushEvent("nav", {dir: -1})
              }
            }
            window.addEventListener("keydown", this.onKey)

            this.handleEvent("goto_slide", ({index}) => {
              const el = document.getElementById(`slide-${index}`)
              if (el) el.scrollIntoView({behavior: "smooth"})
            })

            // Background-generated PDF is ready — pull it through a real
            // anchor click so it lands in the browser's download manager
            this.handleEvent("trigger_download", ({url}) => {
              const a = document.createElement("a")
              a.href = url
              a.download = ""
              document.body.appendChild(a)
              a.click()
              a.remove()
            })

            // Empty slide space opens the slide's options (edit mode only —
            // the server ignores it otherwise). Clicks that belong to a
            // block, control, or overlay are left alone.
            this.onBgClick = (e) => {
              const section = e.target.closest("section[data-slide-id]")
              if (!section) return
              if (e.target.closest("[phx-value-block], button, a, form, input, textarea, select, label")) return
              const index = parseInt(section.id.replace("slide-", ""), 10)
              this.pushEvent("select_slide_bg", {index})
            }
            this.el.addEventListener("click", this.onBgClick)
          },
          destroyed() {
            window.removeEventListener("keydown", this.onKey)
          }
        }
      </script>
    </main>
    """
  end

  # ----- Options panel ----------------------------------------------------------
  #
  # Layered selection: a block click edits that text directly (no model);
  # the slide-level panel is generation-oriented (agent prompt, add parts,
  # size, delete).

  attr(:selected, :map, required: true)
  attr(:slide, Uitstalling.Decks.Slide, required: true)
  attr(:value, :any, default: nil)
  attr(:edit_form, :map, default: %{})
  attr(:addable, :list, default: [])
  attr(:edit_error, :string, default: nil)
  attr(:uploads, :any, default: nil)

  defp options_panel(assigns) do
    kind = assigns.selected.block && block_kind(assigns.selected.block)

    assigns =
      assigns
      |> assign(:kind, kind)
      |> assign(:gen_prompt, gen_prompt(kind, assigns.value))

    ~H"""
    <div class="fixed inset-0 z-50 bg-zinc-950/80 flex items-center justify-center p-4 sm:p-6">
      <div class="w-full max-w-xl bg-zinc-900 ring-1 ring-zinc-700 rounded-xl max-h-[90dvh] flex flex-col overflow-hidden">
        <p class="font-mono text-(--ui-a4) text-xs tracking-wider px-6 pt-6 pb-4 shrink-0">
          EDIT SLIDE {@selected.index + 1} · {@slide.layout}
          <span :if={@selected.block} class="text-zinc-400">· {@selected.block}</span>
        </p>

        <div class="flex-1 min-h-0 overflow-y-auto px-6 pb-2">
          <%= if @selected.block do %>
            <%!-- Image part: upload + alt + treatment, no model involved --%>
            <form
              :if={@kind == :image and @uploads}
              id="image-form"
              phx-submit="save_image"
              phx-change="validate_image"
            >
              <div :if={@value} class="mb-4">
                <img
                  src={"/a/#{@value["asset_id"]}"}
                  alt={@value["alt"] || ""}
                  class="max-h-40 rounded-lg ring-1 ring-zinc-700"
                />
              </div>

              <p class="font-mono text-zinc-500 text-xs mb-2">
                {if @value, do: "UPLOAD A REPLACEMENT", else: "UPLOAD AN IMAGE"} · png / jpg / webp / gif · ≤ 5MB
              </p>
              <.live_file_input
                upload={@uploads.image}
                class="w-full text-sm text-zinc-400 file:mr-4 file:px-4 file:py-2 file:rounded-lg file:border-0 file:bg-zinc-800 file:text-zinc-200 hover:file:bg-zinc-700"
              />
              <p
                :for={err <- upload_errors(@uploads.image)}
                class="mt-1 text-red-400 text-xs font-mono"
              >
                {upload_error_msg(err)}
              </p>
              <div :for={entry <- @uploads.image.entries} class="mt-2">
                <p class="font-mono text-xs text-zinc-400">{entry.client_name} — {entry.progress}%</p>
                <p
                  :for={err <- upload_errors(@uploads.image, entry)}
                  class="text-red-400 text-xs font-mono"
                >
                  {upload_error_msg(err)}
                </p>
              </div>

              <p class="font-mono text-zinc-500 text-xs mt-4 mb-1">CAPTION / ALT TEXT (optional)</p>
              <input
                type="text"
                name="alt"
                value={@edit_form["alt"] || (@value && @value["alt"])}
                class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-(--ui-a5) border-0 p-3 font-sans"
              />

              <div :if={@value} class="mt-4">
                <p class="font-mono text-zinc-500 text-xs mb-1">
                  CROP &amp; ZOOM — drag to reposition · pull a corner in to crop
                  tighter · slide to zoom
                </p>
                <div
                  id="crop-preview"
                  phx-hook=".ImageCrop"
                  phx-update="ignore"
                  data-x={crop_part(@value, "x")}
                  data-y={crop_part(@value, "y")}
                  data-zoom={crop_part(@value, "zoom")}
                  class="relative aspect-video rounded-lg overflow-hidden ring-1 ring-zinc-700 bg-zinc-950 cursor-move select-none touch-none"
                >
                  <img
                    src={"/a/#{@value["asset_id"]}"}
                    class="w-full h-full object-cover pointer-events-none"
                    draggable="false"
                  />
                  <%!-- 16:9-locked selection rect; the hook owns geometry --%>
                  <div
                    id="crop-rect"
                    class="absolute inset-0 border-2 border-dashed border-white/70"
                    style="pointer-events: none"
                  >
                    <span
                      :for={
                        {corner, pos, cursor} <- [
                          {"nw", "-top-1.5 -left-1.5", "cursor-nwse-resize"},
                          {"ne", "-top-1.5 -right-1.5", "cursor-nesw-resize"},
                          {"sw", "-bottom-1.5 -left-1.5", "cursor-nesw-resize"},
                          {"se", "-bottom-1.5 -right-1.5", "cursor-nwse-resize"}
                        ]
                      }
                      data-corner={corner}
                      class={[
                        "absolute w-3.5 h-3.5 bg-white rounded-sm ring-1 ring-zinc-500",
                        pos,
                        cursor
                      ]}
                      style="pointer-events: auto"
                    ></span>
                  </div>
                </div>
                <div class="mt-2 flex items-center gap-3">
                  <input
                    type="range"
                    id="crop-zoom-slider"
                    min="1"
                    max="4"
                    step="0.05"
                    value={crop_part(@value, "zoom")}
                    class="flex-1 accent-(--ui-a5)"
                  />
                  <button
                    type="button"
                    id="crop-apply"
                    hidden
                    class="font-mono text-xs px-3 py-1.5 rounded bg-(--ui-a5) hover:bg-(--ui-a4) text-zinc-950 font-semibold"
                  >
                    ✓ crop to selection
                  </button>
                  <button
                    type="button"
                    id="crop-reset"
                    class="font-mono text-xs text-zinc-500 hover:text-(--ui-a4)"
                  >
                    reset
                  </button>
                </div>
                <input type="hidden" name="crop_x" id="crop-x" value={crop_part(@value, "x")} />
                <input type="hidden" name="crop_y" id="crop-y" value={crop_part(@value, "y")} />
                <input
                  type="hidden"
                  name="crop_zoom"
                  id="crop-zoom"
                  value={crop_part(@value, "zoom")}
                />
              </div>

              <script :type={Phoenix.LiveView.ColocatedHook} name=".ImageCrop">
                export default {
                  mounted() {
                    this.img = this.el.querySelector("img")
                    this.rectEl = this.el.querySelector("#crop-rect")
                    this.x = parseFloat(this.el.dataset.x)
                    this.y = parseFloat(this.el.dataset.y)
                    this.zoom = parseFloat(this.el.dataset.zoom)
                    // Selection rect as frame fractions; 16:9-locked so one
                    // width doubles as its height
                    this.sel = {left: 0, top: 0, w: 1}
                    this.apply()

                    this.el.addEventListener("pointerdown", (e) => {
                      const corner = e.target.dataset && e.target.dataset.corner
                      const frame = this.el.getBoundingClientRect()
                      if (corner) {
                        // Resize anchored at the opposite corner
                        const ax = corner.includes("w") ? this.sel.left + this.sel.w : this.sel.left
                        const ay = corner.includes("n") ? this.sel.top + this.sel.w : this.sel.top
                        this.drag = {mode: "resize", ax, ay, frame}
                      } else if (this.sel.w < 1 && this.inSel(e, frame)) {
                        this.drag = {mode: "move", sx: e.clientX, sy: e.clientY, left: this.sel.left, top: this.sel.top, frame}
                      } else {
                        this.drag = {mode: "pan", sx: e.clientX, sy: e.clientY, x: this.x, y: this.y, frame}
                      }
                      this.el.setPointerCapture(e.pointerId)
                      e.preventDefault()
                    })

                    this.el.addEventListener("pointermove", (e) => {
                      if (!this.drag) return
                      const d = this.drag, frame = d.frame

                      if (d.mode === "pan") {
                        this.x = this.clamp(d.x - ((e.clientX - d.sx) / frame.width) * 100 / this.zoom)
                        this.y = this.clamp(d.y - ((e.clientY - d.sy) / frame.height) * 100 / this.zoom)
                        this.apply()
                      } else if (d.mode === "resize") {
                        const cx = (e.clientX - frame.left) / frame.width
                        const cy = (e.clientY - frame.top) / frame.height
                        const sx = cx < d.ax ? -1 : 1
                        const sy = cy < d.ay ? -1 : 1
                        const avail = Math.min(sx > 0 ? 1 - d.ax : d.ax, sy > 0 ? 1 - d.ay : d.ay)
                        const w = Math.min(Math.max(Math.max(Math.abs(cx - d.ax), Math.abs(cy - d.ay)), 0.15), avail)
                        this.sel = {left: sx > 0 ? d.ax : d.ax - w, top: sy > 0 ? d.ay : d.ay - w, w}
                        this.drawSel()
                      } else if (d.mode === "move") {
                        this.sel.left = Math.min(Math.max(d.left + (e.clientX - d.sx) / frame.width, 0), 1 - this.sel.w)
                        this.sel.top = Math.min(Math.max(d.top + (e.clientY - d.sy) / frame.height, 0), 1 - this.sel.w)
                        this.drawSel()
                      }
                    })

                    this.el.addEventListener("pointerup", () => {
                      if (this.drag && this.drag.mode === "pan") this.sync()
                      this.drag = null
                    })

                    document.getElementById("crop-zoom-slider").addEventListener("input", (e) => {
                      this.zoom = parseFloat(e.target.value)
                      this.apply()
                      this.sync()
                    })
                    document.getElementById("crop-apply").addEventListener("click", () => this.applySel())
                    document.getElementById("crop-reset").addEventListener("click", () => {
                      this.x = 50; this.y = 50; this.zoom = 1
                      this.resetSel()
                      this.apply()
                      this.sync()
                    })
                  },

                  inSel(e, frame) {
                    const fx = (e.clientX - frame.left) / frame.width
                    const fy = (e.clientY - frame.top) / frame.height
                    return fx >= this.sel.left && fx <= this.sel.left + this.sel.w &&
                      fy >= this.sel.top && fy <= this.sel.top + this.sel.w
                  },

                  // Zoom into the selected sub-rect of the CURRENT view.
                  // Per axis with object-position P (fraction) and coverage
                  // k = zoom * rendered/frame: visible window starts at
                  // P(k-1)/k, so the new P solves P'(k'-1)/k' = old window
                  // start + rect offset / k, with k' = k / w.
                  applySel() {
                    const {left, top, w} = this.sel
                    if (w >= 0.999) return
                    const frame = this.el.getBoundingClientRect()
                    const imgAR = this.img.naturalWidth / this.img.naturalHeight
                    const frameAR = frame.width / frame.height
                    const kx = this.zoom * Math.max(1, imgAR / frameAR)
                    const ky = this.zoom * Math.max(1, frameAR / imgAR)

                    const zTarget = Math.min(this.zoom / w, 4)
                    // If zoom clamps, keep the selection's center instead
                    const wEff = this.zoom / zTarget
                    const a = Math.min(Math.max(left + w / 2 - wEff / 2, 0), 1 - wEff)
                    const b = Math.min(Math.max(top + w / 2 - wEff / 2, 0), 1 - wEff)

                    const newP = (P, k, offset) =>
                      Math.abs(k - wEff) < 1e-6 ? 50 : this.clamp(((P / 100) * (k - 1) + offset) / (k - wEff) * 100)

                    this.x = newP(this.x, kx, a)
                    this.y = newP(this.y, ky, b)
                    this.zoom = zTarget
                    document.getElementById("crop-zoom-slider").value = zTarget
                    this.resetSel()
                    this.apply()
                    this.sync()
                  },

                  drawSel() {
                    const {left, top, w} = this.sel
                    const full = w >= 0.999
                    Object.assign(this.rectEl.style, {
                      left: `${left * 100}%`,
                      top: `${top * 100}%`,
                      width: `${w * 100}%`,
                      height: `${w * 100}%`,
                      inset: "",
                      pointerEvents: full ? "none" : "auto",
                      cursor: full ? "" : "move",
                      boxShadow: full ? "" : "0 0 0 9999px rgba(0,0,0,0.55)"
                    })
                    document.getElementById("crop-apply").hidden = full
                  },

                  resetSel() {
                    this.sel = {left: 0, top: 0, w: 1}
                    this.drawSel()
                  },

                  clamp(v) { return Math.min(100, Math.max(0, v)) },

                  apply() {
                    this.img.style.objectPosition = `${this.x}% ${this.y}%`
                    this.img.style.transform = `scale(${this.zoom})`
                    this.img.style.transformOrigin = `${this.x}% ${this.y}%`
                  },

                  // Push into the form's hidden inputs so phx-change stores it in
                  // edit_form and Save persists it
                  sync() {
                    for (const [id, v] of [["crop-x", this.x], ["crop-y", this.y], ["crop-zoom", this.zoom]]) {
                      const input = document.getElementById(id)
                      input.value = v
                      input.dispatchEvent(new Event("input", {bubbles: true}))
                    }
                  }
                }
              </script>

              <p class="font-mono text-zinc-500 text-xs mt-4 mb-1">SIZE</p>
              <div class="flex gap-4">
                <label
                  :for={{treatment, label} <- [{"side", "inset"}, {"full", "full width"}]}
                  class="flex items-center gap-2 font-mono text-sm text-zinc-300 cursor-pointer"
                >
                  <input
                    type="radio"
                    name="treatment"
                    value={treatment}
                    checked={
                      (@edit_form["treatment"] || (@value && @value["treatment"]) || "side") ==
                        treatment
                    }
                    class="text-(--ui-a5) bg-zinc-950 border-zinc-700 focus:ring-(--ui-a5)"
                  /> {label}
                </label>
              </div>

              <div class="sticky bottom-0 mt-4 py-2 bg-zinc-900 flex justify-end">
                <button
                  type="submit"
                  class="px-5 py-2 rounded-lg bg-(--ui-a5) hover:bg-(--ui-a4) text-zinc-950 font-semibold"
                >
                  Save image
                </button>
              </div>
            </form>

            <div :if={@kind == :image} class="mt-6 pt-4 border-t border-zinc-800">
              <p class="font-mono text-zinc-500 text-xs mb-2">
                {cond do
                  @gen_prompt ->
                    "OR REGENERATE IT — tweak the prompt and go again"

                  @value ->
                    "OR PROMPT ON TOP OF IT — the current image rides along as " <>
                      "reference, so you're generating against it; untick to " <>
                      "start fresh"

                  true ->
                    "OR DESCRIBE IT AND GENERATE"
                end}
              </p>
              <form
                id="image-gen-form"
                phx-submit="queue_image_gen"
                phx-change="validate_edit"
                class="mt-2"
              >
                <textarea
                  name="prompt"
                  rows="3"
                  placeholder="e.g. a clean isometric illustration of a phishing proxy between a user and a bank"
                  class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-(--ui-a5) border-0 p-4 font-sans"
                >{@edit_form["prompt"] || @gen_prompt}</textarea>
                <label
                  :if={@value}
                  class="mt-3 flex items-center gap-2 font-mono text-sm text-zinc-300 cursor-pointer"
                >
                  <input type="hidden" name="use_reference" value="false" />
                  <input
                    type="checkbox"
                    name="use_reference"
                    value="true"
                    checked={@edit_form["use_reference"] != "false"}
                    class="rounded bg-zinc-950 border-zinc-700 text-(--ui-a5) focus:ring-(--ui-a5)"
                  /> use the current image as reference
                </label>
                <p class="font-mono text-zinc-500 text-xs mt-3 mb-1">MODEL</p>
                <select
                  name="model"
                  class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-(--ui-a5) border-0 p-3 font-mono text-sm"
                >
                  {Phoenix.HTML.Form.options_for_select(
                    Uitstalling.Assets.ImageModels.options(),
                    @edit_form["model"] || Uitstalling.Assets.ImageModels.default()
                  )}
                </select>
                <div class="mt-3 flex justify-end">
                  <button
                    type="submit"
                    class="px-6 py-2.5 rounded-lg bg-(--ui-a5) hover:bg-(--ui-a4) text-zinc-950 font-semibold"
                  >
                    {if @gen_prompt, do: "Regenerate image", else: "Generate image"}
                  </button>
                </div>
              </form>
            </div>

            <%!-- Block level: edit the text exactly. Typed state (@edit_form)
                 wins over the stored value, so background deck updates can't
                 reset an editor mid-thought. --%>
            <form
              :if={@kind not in [:agent_only, :image]}
              id="block-form"
              phx-submit="save_text"
              phx-change="validate_edit"
            >
              <%= case @kind do %>
                <% :scalar -> %>
                  <textarea
                    name="value"
                    rows={if @selected.block in ~w(heading kicker), do: 2, else: 4}
                    class={[
                      "w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-(--ui-a5) border-0 p-4",
                      if(@selected.block == "code", do: "font-mono", else: "font-sans")
                    ]}
                  >{@edit_form["value"] || @value}</textarea>
                <% :lines -> %>
                  <p class="font-mono text-zinc-500 text-xs mb-2">ONE ITEM PER LINE</p>
                  <textarea
                    name="value"
                    rows="6"
                    class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-(--ui-a5) border-0 p-4 font-sans"
                  >{@edit_form["value"] || Enum.join(@value, "\n")}</textarea>
                <% :row -> %>
                  <div
                    :for={{col, ci} <- Enum.with_index(@slide.fields["columns"] || [])}
                    class="mb-3"
                  >
                    <p class="font-mono text-zinc-500 text-xs mb-1 uppercase">{col}</p>
                    <textarea
                      name={"cell_#{ci}"}
                      rows="2"
                      class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-(--ui-a5) border-0 p-3 font-sans"
                    >{@edit_form["cell_#{ci}"] || row_cell_text(@value, ci)}</textarea>
                  </div>
                <% {:map, fields} -> %>
                  <div :for={field <- fields} class="mb-3">
                    <p class="font-mono text-zinc-500 text-xs mb-1 uppercase">{field}</p>
                    <textarea
                      name={field}
                      rows={if field in ~w(body a), do: 3, else: 1}
                      class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-(--ui-a5) border-0 p-3 font-sans"
                    >{@edit_form[field] || @value[field]}</textarea>
                  </div>
              <% end %>
              <p class="mt-2 font-mono text-zinc-600 text-xs">
                markup: **strong** · ==accent== · ~~strike~~ · `code`
              </p>
              <div class="sticky bottom-0 mt-3 py-2 bg-zinc-900 flex justify-end">
                <button
                  type="submit"
                  class="px-5 py-2 rounded-lg bg-(--ui-a5) hover:bg-(--ui-a4) text-zinc-950 font-semibold"
                >
                  Save
                </button>
              </div>
            </form>

            <p :if={@kind == :agent_only} class="text-zinc-400 text-sm">
              This part is best edited via the agent — describe the change below.
            </p>

            <%!-- The agent never touches images (app-managed key) --%>
            <div
              :if={@kind != :image}
              class={@kind != :agent_only && "mt-6 pt-4 border-t border-zinc-800"}
            >
              <p :if={@kind != :agent_only} class="font-mono text-zinc-500 text-xs mb-2">
                OR ASK THE AGENT TO WRITE IT
              </p>
              <.agent_form
                placeholder={"e.g. reword this #{@selected.block} more simply"}
                value={@edit_form["prompt"]}
              />
            </div>
          <% else %>
            <%!-- Slide level: generation-oriented --%>
            <p class="font-mono text-zinc-500 text-xs mb-2">DESCRIBE THE CHANGES</p>
            <.agent_form
              placeholder="e.g. rework this slide around three punchy takeaways"
              value={@edit_form["prompt"]}
            />

            <div :if={@addable != []} class="mt-6">
              <p class="font-mono text-zinc-500 text-xs mb-2">ADD A PART</p>
              <div class="flex flex-wrap gap-2">
                <button
                  :for={{label, key} <- @addable}
                  phx-click="add_block"
                  phx-value-key={key}
                  class="px-4 py-2.5 rounded-lg font-mono text-sm ring-1 bg-zinc-950 text-zinc-400 ring-zinc-700 hover:text-(--ui-a4) hover:ring-(--ui-a5) transition"
                >
                  + {label}
                </button>
              </div>
              <p class="mt-2 font-mono text-zinc-600 text-xs">
                opens the new part's editor — type it exactly, or have it generated
              </p>
            </div>

            <div class="mt-6">
              <p class="font-mono text-zinc-500 text-xs mb-2">GROW THE DECK</p>
              <button
                phx-click="add_slide"
                class="px-4 py-2.5 rounded-lg font-mono text-sm ring-1 bg-zinc-950 text-zinc-400 ring-zinc-700 hover:text-(--ui-a4) hover:ring-(--ui-a5) transition"
              >
                + add a slide after this one
              </button>
              <p class="mt-2 font-mono text-zinc-600 text-xs">
                opens the new slide's editor — type it exactly, or have the agent write it
              </p>
            </div>

            <div class="mt-6">
              <p class="font-mono text-zinc-500 text-xs mb-2">
                SLIDE TONE — colour for this slide only
              </p>
              <div class="flex gap-2">
                <button
                  :for={tone <- Decks.tones()}
                  phx-click="set_tone"
                  phx-value-tone={tone}
                  class={[
                    "px-4 py-2 rounded-lg font-mono text-sm ring-1 transition",
                    if(@slide.tone == tone,
                      do: "bg-(--ui-a5) text-zinc-950 ring-(--ui-a4) font-bold",
                      else: "bg-zinc-950 text-zinc-400 ring-zinc-700 hover:text-(--ui-a4)"
                    )
                  ]}
                >
                  {tone}
                </button>
              </div>
            </div>

            <div class="mt-6">
              <p class="font-mono text-zinc-500 text-xs mb-2">TEXT SIZE</p>
              <div class="flex gap-2">
                <button
                  :for={size <- ~w(sm md lg)}
                  phx-click="set_size"
                  phx-value-size={size}
                  class={[
                    "px-4 py-2 rounded-lg font-mono text-sm ring-1 transition",
                    if(@slide.size == size,
                      do: "bg-(--ui-a5) text-zinc-950 ring-(--ui-a4) font-bold",
                      else: "bg-zinc-950 text-zinc-400 ring-zinc-700 hover:text-(--ui-a4)"
                    )
                  ]}
                >
                  {String.upcase(size)}
                </button>
              </div>
            </div>
          <% end %>

          <p
            :if={@edit_error}
            class="mt-4 p-3 bg-red-950 ring-1 ring-red-700 rounded text-red-200 text-sm font-mono"
          >
            {@edit_error}
          </p>
        </div>

        <div class="shrink-0 px-6 py-4 border-t border-zinc-800 flex items-center justify-between">
          <div class="flex gap-3">
            <button
              :if={@selected.block}
              phx-click="delete"
              class="px-5 py-2.5 rounded-lg text-red-400 ring-1 ring-red-900 hover:bg-red-950 font-mono text-sm"
            >
              Delete {block_label(@selected.block)}
            </button>
            <button
              :if={is_nil(@selected.block)}
              phx-click="delete_slide"
              class="px-5 py-2.5 rounded-lg text-red-400 ring-1 ring-red-900 hover:bg-red-950 font-mono text-sm"
            >
              Delete slide
            </button>
            <%!-- An empty media frame ("image goes here") is the layout
                 itself — removing it means becoming a text slide --%>
            <button
              :if={
                is_nil(@selected.block) and @slide.layout == "media" and
                  is_nil(@slide.fields["src"])
              }
              phx-click="remove_media_frame"
              class="px-5 py-2.5 rounded-lg text-zinc-400 ring-1 ring-zinc-700 hover:text-(--ui-a4) hover:ring-(--ui-a5) font-mono text-sm"
            >
              Remove media frame
            </button>
          </div>
          <button
            phx-click="cancel_edit"
            class="px-5 py-2.5 rounded-lg text-zinc-300 ring-1 ring-zinc-700 hover:text-zinc-100 hover:ring-zinc-500"
          >
            Close
          </button>
        </div>
      </div>
    </div>
    """
  end

  # If the current image was generated, its stored prompt is the author's own
  # subject — offered back so a regenerate starts from what produced this one.
  defp gen_prompt(:image, %{"asset_id" => asset_id}) do
    case Assets.get(asset_id) do
      %{origin: "gen", prompt: prompt} when is_binary(prompt) -> prompt
      _ -> nil
    end
  end

  defp gen_prompt(_kind, _value), do: nil

  # ----- Regenerate-deck panel ---------------------------------------------------
  #
  # The original create request (prompt + research grounding) offered back for
  # editing; submitting queues a fresh create for this same deck.

  attr(:regen, :map, required: true)

  defp regen_panel(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 bg-zinc-950/80 flex items-center justify-center p-4 sm:p-6">
      <div class="w-full max-w-xl bg-zinc-900 ring-1 ring-zinc-700 rounded-xl max-h-[90dvh] flex flex-col overflow-hidden">
        <p class="font-mono text-(--ui-a4) text-xs tracking-wider px-6 pt-6 pb-4 shrink-0">
          REGENERATE THIS DECK
        </p>

        <form
          id="regen-form"
          phx-submit="queue_regen"
          phx-change="validate_regen"
          class="flex-1 min-h-0 overflow-y-auto px-6 pb-2"
        >
          <p class="text-zinc-400 text-sm mb-4">
            Rework the brief and generate the deck fresh — theme and length stay
            as chosen ({@regen["theme"]}<span :if={@regen["minutes"]}> · {@regen["minutes"]} min</span>).
            The current slides are replaced; undo brings them back.
          </p>

          <p class="font-mono text-zinc-500 text-xs mb-2">THE BRIEF</p>
          <textarea
            name="prompt"
            rows="6"
            placeholder="what the talk is about, and the main points to cover"
            class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-(--ui-a5) border-0 p-4 font-sans"
          >{@regen["prompt"]}</textarea>

          <p class="font-mono text-zinc-500 text-xs mt-4 mb-2">TONE &amp; AUDIENCE</p>
          <input
            type="text"
            name="voice"
            value={@regen["voice"]}
            placeholder="e.g. sharp and technical, for a security-savvy crowd"
            class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-(--ui-a5) border-0 p-3 font-sans"
          />

          <p class="font-mono text-zinc-500 text-xs mt-4 mb-2">
            RESEARCH / CONTEXT (optional{if @regen["research_filename"],
              do: " — from #{@regen["research_filename"]}"})
          </p>
          <textarea
            name="research"
            rows="6"
            placeholder="facts, numbers, names and quotes to ground the deck in"
            class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-(--ui-a5) border-0 p-4 font-sans text-sm"
          >{@regen["research"]}</textarea>

          <div class="sticky bottom-0 mt-4 py-2 bg-zinc-900 flex justify-end">
            <button
              type="submit"
              class="px-6 py-2.5 rounded-lg bg-(--ui-a5) hover:bg-(--ui-a4) text-zinc-950 font-semibold"
            >
              Regenerate deck
            </button>
          </div>
        </form>

        <div class="shrink-0 px-6 py-4 border-t border-zinc-800 flex justify-end">
          <button
            phx-click="close_regen"
            class="px-5 py-2.5 rounded-lg text-zinc-300 ring-1 ring-zinc-700 hover:text-zinc-100 hover:ring-zinc-500"
          >
            Close
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr(:placeholder, :string, required: true)
  attr(:value, :string, default: nil)

  defp agent_form(assigns) do
    ~H"""
    <form id="agent-form" phx-submit="queue_edit" phx-change="validate_edit" class="mt-2">
      <textarea
        name="prompt"
        rows="3"
        placeholder={@placeholder}
        class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-(--ui-a5) border-0 p-4 font-sans"
      >{@value}</textarea>
      <div class="mt-3 flex justify-end">
        <button
          type="submit"
          class="px-5 py-2 rounded-lg bg-(--ui-a5) hover:bg-(--ui-a4) text-zinc-950 font-semibold"
        >
          Queue for agent
        </button>
      </div>
    </form>
    """
  end

  # How a block is edited directly. Scalars and string-lists get a textarea;
  # map-shaped list items get one field each; table rows stay agent-only.
  defp block_kind(path) do
    case String.split(path, ".") do
      ["image"] -> :image
      # Whole "columns" is the table's header row (bullets use columns.N)
      ["columns"] -> :lines
      ["columns", _] -> :lines
      ["points", _] -> {:map, ~w(label body)}
      ["items", _] -> {:map, ~w(q a)}
      ["steps", _] -> {:map, ~w(actor body arrow_label)}
      # A table row: one field per column; tints survive text edits
      ["rows", _] -> :row
      ["rows"] -> :agent_only
      [_scalar] -> :scalar
      # Anything else (incl. depth-3 paths) is edited via the agent for now
      _ -> :agent_only
    end
  end

  # Friendlier names for the Delete button ("Delete row 3", not "Delete rows.2")
  defp block_label(path) do
    case String.split(path, ".") do
      ["rows", n] -> "row #{String.to_integer(n) + 1}"
      ["points", n] -> "point #{String.to_integer(n) + 1}"
      ["steps", n] -> "step #{String.to_integer(n) + 1}"
      ["items", n] -> "question #{String.to_integer(n) + 1}"
      ["columns", n] -> "bullet column #{String.to_integer(n) + 1}"
      _ -> path
    end
  end

  defp row_cell_text(row, ci) do
    case Enum.at(row || [], ci) do
      %{"text" => text} -> text
      cell when is_binary(cell) -> cell
      _ -> nil
    end
  end

  # ----- Navigation ---------------------------------------------------------

  # Only the presenter's keyboard drives the room — a public viewer's arrow
  # keys navigate their own copy quietly.
  def handle_event("nav", %{"dir" => dir}, socket) do
    mode = if socket.assigns.can_edit, do: :broadcast, else: :quiet
    {:noreply, goto(socket, socket.assigns.index + dir, mode)}
  end

  # ----- PDF download -----------------------------------------------------------
  #
  # Anyone who can view can download. The video check runs here, on click —
  # not on every render: a deck with video gets a heads-up modal (those
  # slides degrade to a placeholder in the PDF); one without exports
  # immediately. Generation happens in a background task; the finished PDF
  # is parked in PdfStore and the browser pulls it by token, so the page
  # never navigates and the file lands in the download manager.

  def handle_event("open_pdf", _params, socket) do
    if Decks.has_video?(socket.assigns.deck) do
      {:noreply, assign(socket, pdf_modal: true)}
    else
      {:noreply, start_pdf(socket)}
    end
  end

  def handle_event("start_pdf", _params, socket) do
    {:noreply, start_pdf(socket)}
  end

  def handle_event("close_pdf", _params, socket) do
    {:noreply, assign(socket, pdf_modal: false)}
  end

  def handle_event("dismiss_pdf_error", _params, socket) do
    {:noreply, assign(socket, pdf_error: nil)}
  end

  # ----- Edit mode ------------------------------------------------------------

  # AUTHORIZE every mutating event server-side — a client can push these
  # regardless of what the UI renders. Non-authors get a no-op.
  @edit_events ~w(toggle_edit select_block select_slide select_slide_bg save_text set_size set_tone
                  add_block add_slide delete delete_slide remove_media_frame undo
                  queue_edit validate_edit
                  save_image validate_image queue_image_gen
                  open_regen close_regen queue_regen validate_regen
                  open_theme close_theme set_theme
                  cancel_request dismiss_failure)

  def handle_event(event, _params, %{assigns: %{can_edit: false}} = socket)
      when event in @edit_events do
    {:noreply, socket}
  end

  def handle_event("toggle_edit", _params, socket) do
    {:noreply,
     assign(socket, edit_mode: !socket.assigns.edit_mode, selected: nil, edit_form: %{})}
  end

  def handle_event("select_block", %{"index" => index, "block" => block}, socket) do
    # `block` is client-supplied — a path the parser rejects is ignored
    # rather than crashing pattern matches downstream.
    with {:ok, index} <- parse_index(socket, index),
         {:ok, _parsed} <- Uitstalling.Decks.BlockPath.parse(block) do
      {:noreply,
       assign(socket, selected: %{index: index, block: block}, edit_form: %{}, edit_error: nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("select_slide", %{"index" => index}, socket) do
    with {:ok, index} <- parse_index(socket, index) do
      {:noreply,
       assign(socket, selected: %{index: index, block: nil}, edit_form: %{}, edit_error: nil)}
    end
  end

  # Background (empty-space) clicks come from the DeckNav hook on every
  # click — they only mean "slide options" while editing.
  def handle_event("select_slide_bg", %{"index" => index}, socket) do
    with true <- socket.assigns.edit_mode,
         {:ok, index} <- parse_index(socket, index) do
      {:noreply,
       assign(socket, selected: %{index: index, block: nil}, edit_form: %{}, edit_error: nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, selected: nil, edit_form: %{}, edit_error: nil)}
  end

  # Hold typed-but-unsaved editor fields server-side (all editor forms
  # phx-change here; keys don't collide across the forms visible together).
  def handle_event("validate_edit", params, socket) do
    {:noreply, assign(socket, edit_form: merge_edit_form(socket, params))}
  end

  # ----- Direct mutations (no model involved) ----------------------------------

  def handle_event("save_text", params, socket) do
    %{index: index, block: block} = socket.assigns.selected
    raw = socket.assigns.raw

    new_raw =
      case {block_kind(block), params} do
        {:scalar, %{"value" => value}} ->
          case String.trim(value) do
            # Emptying a text field deletes it — the validator protects
            # required fields.
            "" -> Decks.delete_block(raw, index, block)
            trimmed -> Decks.put_block(raw, index, block, trimmed)
          end

        {:lines, %{"value" => value}} ->
          lines =
            value |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

          Decks.put_block(raw, index, block, lines)

        {{:map, fields}, params} ->
          existing = Decks.get_block(raw, index, block) || %{}

          updated =
            Enum.reduce(fields, existing, fn field, acc ->
              case String.trim(params[field] || "") do
                "" -> Map.delete(acc, field)
                value -> Map.put(acc, field, value)
              end
            end)

          Decks.put_block(raw, index, block, updated)

        {:row, params} ->
          columns = Enum.at(raw["slides"], index)["columns"] || []
          existing = Decks.get_block(raw, index, block) || []

          # Rebuild the row column by column; structured cells keep their
          # tint, only the text changes.
          row =
            for ci <- 0..(length(columns) - 1) do
              text = String.trim(params["cell_#{ci}"] || "")

              case Enum.at(existing, ci) do
                %{} = cell -> Map.put(cell, "text", text)
                _ -> text
              end
            end

          Decks.put_block(raw, index, block, row)
      end

    {:noreply, commit(socket, new_raw)}
  end

  def handle_event("set_size", %{"size" => size}, socket) when size in ~w(sm md lg) do
    %{index: index} = socket.assigns.selected
    {:noreply, commit(socket, Decks.put_slide_key(socket.assigns.raw, index, "size", size))}
  end

  def handle_event("set_tone", %{"tone" => tone}, socket) do
    if tone in Decks.tones() do
      %{index: index} = socket.assigns.selected
      {:noreply, commit(socket, Decks.put_slide_key(socket.assigns.raw, index, "tone", tone))}
    else
      {:noreply, socket}
    end
  end

  # Images have no text placeholder to commit — adding one just opens the
  # image editor; the slide changes only when an upload is saved.
  def handle_event("add_block", %{"key" => "image"}, socket) do
    %{index: index} = socket.assigns.selected

    {:noreply,
     assign(socket, selected: %{index: index, block: "image"}, edit_form: %{}, edit_error: nil)}
  end

  # Adds a valid placeholder through the normal commit path (undo-able), then
  # drops straight into the editor for the new part.
  def handle_event("add_block", %{"key" => key}, socket) do
    %{index: index} = socket.assigns.selected
    raw = socket.assigns.raw
    raw_slide = Enum.at(raw["slides"], index)

    {new_raw, new_path} =
      if key in ~w(columns points steps rows items) do
        item = list_placeholder(key, raw_slide)
        pos = length(raw_slide[key] || [])
        {Decks.append_item(raw, index, key, item), "#{key}.#{pos}"}
      else
        {Decks.put_block(raw, index, key, @scalar_placeholders[key] || "…"), key}
      end

    socket = commit(socket, new_raw)

    socket =
      if socket.assigns.edit_error,
        do: socket,
        else: assign(socket, selected: %{index: index, block: new_path}, edit_form: %{})

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    %{index: index, block: block} = socket.assigns.selected
    {:noreply, commit(socket, Decks.delete_block(socket.assigns.raw, index, block))}
  end

  # ----- Images (app-managed asset references) ----------------------------------

  def handle_event("validate_image", params, socket) do
    {:noreply, assign(socket, edit_form: merge_edit_form(socket, params))}
  end

  def handle_event("queue_image_gen", %{"prompt" => prompt} = params, socket) do
    prompt = String.trim(prompt)

    if prompt == "" do
      {:noreply, socket}
    else
      %{index: index} = socket.assigns.selected
      slide = Enum.at(socket.assigns.deck.slides, index)

      # Only a known model id rides along — anything else means the default.
      model = params["model"]

      # Reference is ON by default whenever the part holds an image — you're
      # generating against what's there unless explicitly unticked.
      reference =
        if params["use_reference"] != "false" do
          case Decks.get_block(socket.assigns.raw, index, "image") do
            %{"asset_id" => asset_id} -> asset_id
            _ -> nil
          end
        end

      Decks.queue_request(
        %{
          "type" => "asset",
          "deck_id" => socket.assigns.deck_id,
          "slide_id" => slide.id,
          "block" => "image",
          "prompt" => prompt
        }
        |> then(fn request ->
          if Uitstalling.Assets.ImageModels.valid?(model),
            do: Map.put(request, "model", model),
            else: request
        end)
        |> then(fn request ->
          if reference, do: Map.put(request, "reference_asset_id", reference), else: request
        end)
      )

      Phoenix.PubSub.broadcast_from(
        Uitstalling.PubSub,
        self(),
        socket.assigns.topic,
        :queue_updated
      )

      Decks.DeckWorker.kick(socket.assigns.deck_id)

      {:noreply, socket |> assign(selected: nil, edit_form: %{}) |> refresh_pending()}
    end
  end

  def handle_event("save_image", params, socket) do
    %{index: index} = socket.assigns.selected

    consumed =
      consume_uploaded_entries(socket, :image, fn %{path: path}, _entry ->
        {:ok, Assets.create_upload(socket.assigns.current_user.id, path)}
      end)

    existing = Decks.get_block(socket.assigns.raw, index, "image")

    case {consumed, existing} do
      {[{:ok, asset}], _} ->
        # A fresh file starts uncropped — the old image's pan/zoom is
        # meaningless on it.
        {:noreply,
         save_image_block(socket, index, asset.id, Map.drop(params, ~w(crop_x crop_y crop_zoom)))}

      {[{:error, reason}], _} ->
        {:noreply, assign(socket, edit_error: upload_failure(reason))}

      {[], %{"asset_id" => asset_id}} ->
        # No new file — just updating alt/treatment on the existing image
        {:noreply, save_image_block(socket, index, asset_id, params)}

      {[], nil} ->
        {:noreply, assign(socket, edit_error: "Choose an image file first")}
    end
  end

  # Insert a placeholder after the selected slide through the normal commit
  # path (undo-able, capped by the validator's slide limit), then drop into
  # the new slide's body editor — same pattern as add_block.
  def handle_event("add_slide", _params, socket) do
    %{index: index} = socket.assigns.selected
    socket = commit(socket, Decks.insert_slide(socket.assigns.raw, index))

    if socket.assigns.edit_error do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(selected: %{index: index + 1, block: "body"}, edit_form: %{})
       |> push_event("goto_slide", %{index: index + 1})}
    end
  end

  # Convert an empty media frame into a plain text slide — the frame IS the
  # layout, so "removing" it means becoming a statement. The caption (or
  # heading) carries over as the body so nothing typed is lost.
  def handle_event("remove_media_frame", _params, socket) do
    %{index: index} = socket.assigns.selected
    raw_slide = Enum.at(socket.assigns.raw["slides"], index)

    if raw_slide["layout"] == "media" and is_nil(raw_slide["src"]) do
      body = raw_slide["caption"] || raw_slide["heading"] || "New text…"

      converted =
        raw_slide
        |> Map.drop(~w(kind src caption))
        |> Map.put("layout", "statement")
        |> Map.put("body", body)
        |> then(fn slide ->
          # Don't say the same thing twice when the heading became the body
          if body == raw_slide["heading"], do: Map.delete(slide, "heading"), else: slide
        end)

      new_raw = put_in(socket.assigns.raw, ["slides", Access.at(index)], converted)
      {:noreply, commit(socket, new_raw)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_slide", _params, socket) do
    %{index: index} = socket.assigns.selected
    {:noreply, commit(socket, Decks.delete_slide(socket.assigns.raw, index))}
  end

  def handle_event("undo", _params, socket) do
    case socket.assigns.undo do
      [] ->
        {:noreply, socket}

      [previous | rest] ->
        case Decks.save(
               socket.assigns.deck_id,
               previous,
               socket.assigns.rev,
               socket.assigns.current_user.id
             ) do
          {:ok, rev} ->
            Phoenix.PubSub.broadcast_from(
              Uitstalling.PubSub,
              self(),
              socket.assigns.topic,
              :deck_updated
            )

            {:noreply, socket |> assign(undo: rest, rev: rev) |> load_deck(previous)}

          {:error, :stale} ->
            # The deck moved on since this session's snapshot — undoing over
            # someone else's change would eat it. Refresh; the stack stays.
            {fresh, rev} = Decks.checkout(socket.assigns.deck_id)

            {:noreply,
             socket
             |> assign(
               rev: rev,
               edit_error: "The deck changed underneath — undo aborted, showing the latest."
             )
             |> load_deck(fresh)}
        end
    end
  end

  # ----- Theme switch (direct mutation, no model) ---------------------------------

  def handle_event("open_theme", _params, socket) do
    {:noreply, assign(socket, theme_panel: true, selected: nil)}
  end

  def handle_event("close_theme", _params, socket) do
    {:noreply, assign(socket, theme_panel: false)}
  end

  # Restyle in place through the normal commit path (undo-able, broadcast).
  # The accent re-pairs with the theme so marks stay legible on the new base.
  def handle_event("set_theme", %{"theme" => theme}, socket) do
    if theme in Decks.themes() do
      new_raw =
        socket.assigns.raw
        |> Map.put("theme", theme)
        |> Map.put("accent", Decks.theme_accent(theme))

      {:noreply, socket |> commit(new_raw) |> assign(theme_panel: false)}
    else
      {:noreply, socket}
    end
  end

  # ----- Regenerate the whole deck -----------------------------------------------

  def handle_event("open_regen", _params, socket) do
    # Prefill from the original create request; a deck that predates the
    # request log (or was imported) still gets a usable form from its own
    # stored choices.
    base =
      case Decks.latest_create_request(socket.assigns.deck_id) do
        nil ->
          raw = socket.assigns.raw

          %{
            "theme" => raw["theme"],
            "accent" => raw["accent"],
            "voice" => raw["voice"] || "",
            "minutes" => nil,
            "target_slides" => length(raw["slides"]),
            "prompt" => ""
          }

        request ->
          Map.take(
            request,
            ~w(theme accent voice minutes target_slides prompt research research_filename)
          )
      end

    {:noreply, assign(socket, regen: base, selected: nil, edit_form: %{})}
  end

  def handle_event("close_regen", _params, socket) do
    {:noreply, assign(socket, regen: nil)}
  end

  # Typed regen fields are server-held, same reason as NewDeckLive's form:
  # a patch or reconnect re-renders the panel from @regen, so @regen must
  # carry what's been typed or it gets reset to the prefill.
  def handle_event("validate_regen", params, socket) do
    case socket.assigns.regen do
      nil ->
        {:noreply, socket}

      regen ->
        {:noreply,
         assign(socket, regen: Map.merge(regen, Map.take(params, ~w(prompt voice research))))}
    end
  end

  def handle_event("queue_regen", params, socket) do
    prompt = String.trim(params["prompt"] || "")
    research = String.trim(params["research"] || "")
    voice = String.trim(params["voice"] || "")

    if prompt == "" or socket.assigns.regen == nil do
      {:noreply, socket}
    else
      payload =
        socket.assigns.regen
        |> Map.merge(%{
          "type" => "create",
          "deck_id" => socket.assigns.deck_id,
          "prompt" => prompt
        })
        # An emptied voice field keeps the original — the tweak is retyping it.
        |> then(fn payload ->
          if voice == "", do: payload, else: Map.put(payload, "voice", voice)
        end)
        |> then(fn payload ->
          if research == "",
            do: Map.drop(payload, ~w(research research_filename)),
            else: Map.put(payload, "research", research)
        end)

      Decks.queue_request(payload)

      Phoenix.PubSub.broadcast_from(
        Uitstalling.PubSub,
        self(),
        socket.assigns.topic,
        :queue_updated
      )

      Decks.DeckWorker.kick(socket.assigns.deck_id)

      # The replacement lands via :deck_updated; keep what's on screen now
      # one ↶ away.
      undo = Enum.take([socket.assigns.raw | socket.assigns.undo], @undo_depth)

      {:noreply,
       socket
       |> assign(regen: nil, undo: undo)
       |> refresh_pending()}
    end
  end

  # ----- The agent queue (model tier) -------------------------------------------

  def handle_event("queue_edit", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    if prompt == "" do
      {:noreply, assign(socket, selected: nil, edit_form: %{})}
    else
      %{index: index, block: block} = socket.assigns.selected
      slide = Enum.at(socket.assigns.deck.slides, index)

      Decks.queue_request(%{
        "type" => "edit",
        "deck_id" => socket.assigns.deck_id,
        "slide_id" => slide.id,
        "slide_index" => index,
        "layout" => slide.layout,
        "block" => block,
        "prompt" => prompt
      })

      Phoenix.PubSub.broadcast_from(
        Uitstalling.PubSub,
        self(),
        socket.assigns.topic,
        :queue_updated
      )

      Decks.DeckWorker.kick(socket.assigns.deck_id)

      {:noreply,
       socket
       |> assign(selected: nil, edit_form: %{})
       |> refresh_pending()}
    end
  end

  # Cancel a queued/in-flight generation for this deck: the row flip is final
  # and the deck's worker checks it before persisting anything — a result
  # arriving after this click is discarded.
  def handle_event("cancel_request", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(to_string(id)),
         true <- Enum.any?(socket.assigns.pending, &(&1["id"] == id)) do
      Decks.cancel_request(id)

      Phoenix.PubSub.broadcast_from(
        Uitstalling.PubSub,
        self(),
        socket.assigns.topic,
        :queue_updated
      )

      {:noreply, refresh_pending(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("dismiss_failure", %{"id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {id, ""} ->
        socket = update(socket, :dismissed_failures, &MapSet.put(&1, id))
        {:noreply, refresh_pending(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  # ----- PubSub ---------------------------------------------------------------

  # A remote (or another viewer's keyboard) moved the deck.
  def handle_info({:goto, index}, socket) do
    {:noreply, goto(socket, index, :quiet)}
  end

  # Another session (or the pipeline) changed the deck — reload from the store.
  # LiveView diffing means only the changed parts re-render in the browser.
  # An open editor stays open: typed state lives in @edit_form, so the
  # re-render can't eat it. Only a selection whose slide vanished is dropped.
  def handle_info(:deck_updated, socket) do
    {fresh, rev} = Decks.checkout(socket.assigns.deck_id)
    socket = socket |> assign(rev: rev) |> reload_deck(fresh)

    selected =
      case socket.assigns.selected do
        %{index: index} = selected when index < length(socket.assigns.deck.slides) -> selected
        _ -> nil
      end

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_info(:queue_updated, socket) do
    {:noreply, refresh_pending(socket)}
  end

  # ----- PDF export plumbing ------------------------------------------------------

  defp start_pdf(%{assigns: %{pdf_busy: true}} = socket), do: assign(socket, pdf_modal: false)

  defp start_pdf(socket) do
    deck_id = socket.assigns.deck_id
    filename = "#{Decks.deck_slug(deck_id)}.pdf"

    socket
    |> assign(pdf_modal: false, pdf_busy: true, pdf_error: nil)
    |> start_async(:pdf_export, fn ->
      with {:ok, pdf} <- Decks.Pdf.impl().render(deck_id) do
        {:ok, Decks.PdfStore.put(pdf, filename)}
      end
    end)
  end

  def handle_async(:pdf_export, {:ok, result}, socket) do
    case result do
      {:ok, token} ->
        {:noreply,
         socket
         |> assign(pdf_busy: false)
         |> push_event("trigger_download", %{url: ~p"/pdf/#{token}"})}

      {:error, reason} ->
        Logger.error("PDF export failed for deck #{socket.assigns.deck_id}: #{inspect(reason)}")

        {:noreply,
         assign(socket, pdf_busy: false, pdf_error: "PDF failed — try again in a moment")}
    end
  end

  def handle_async(:pdf_export, {:exit, reason}, socket) do
    Logger.error("PDF export crashed for deck #{socket.assigns.deck_id}: #{inspect(reason)}")
    {:noreply, assign(socket, pdf_busy: false, pdf_error: "PDF failed — try again in a moment")}
  end

  # ----- Helpers ----------------------------------------------------------------

  defp refresh_pending(socket) do
    # open_requests includes the one the pipeline is processing right now —
    # the spinner must not vanish the moment work starts.
    pending =
      Enum.filter(Decks.open_requests(), &(&1["deck_id"] == socket.assigns.deck_id))

    # Failures since this session opened, minus the ones the user dismissed —
    # a generation that dies must say so, not just stop spinning.
    failures =
      Decks.recent_failed_requests(socket.assigns.deck_id, socket.assigns.failures_since)
      |> Enum.reject(&MapSet.member?(socket.assigns.dismissed_failures, &1["id"]))

    assign(socket, pending: pending, failures: failures)
  end

  defp request_label(%{"type" => "create"}), do: "deck"
  defp request_label(%{"type" => "asset"}), do: "image"
  defp request_label(_request), do: "edit"

  # All editor forms share one typed-state map — their input names don't
  # collide across forms that are visible together. "_target" is LiveView
  # bookkeeping, not a field.
  defp merge_edit_form(socket, params),
    do: Map.merge(socket.assigns.edit_form, Map.drop(params, ["_target"]))

  defp pending_specs(pending) do
    for %{"slide_id" => slide_id} = request <- pending, request["type"] != "create" do
      {slide_id, request["block"]}
    end
  end

  defp creating?(pending), do: Enum.any?(pending, &(&1["type"] == "create"))

  defp save_image_block(socket, index, asset_id, params) do
    image =
      %{"asset_id" => asset_id}
      |> maybe_put("alt", String.trim(params["alt"] || ""))
      |> maybe_put("treatment", if(params["treatment"] == "full", do: "full"))
      |> maybe_put("crop", parse_crop(params))

    commit(socket, Decks.put_block(socket.assigns.raw, index, "image", image))
  end

  # Crop values arrive as hidden-input strings from the .ImageCrop hook.
  # Centered at zoom 1 is "no crop": stored as absence, so resetting and
  # saving drops the key entirely.
  defp parse_crop(params) do
    with {x, ""} <- Float.parse(params["crop_x"] || ""),
         {y, ""} <- Float.parse(params["crop_y"] || ""),
         {zoom, ""} <- Float.parse(params["crop_zoom"] || ""),
         true <- zoom > 1.001 or abs(x - 50.0) > 0.5 or abs(y - 50.0) > 0.5 do
      %{
        "x" => x |> min(100.0) |> max(0.0) |> Float.round(1),
        "y" => y |> min(100.0) |> max(0.0) |> Float.round(1),
        "zoom" => zoom |> min(4.0) |> max(1.0) |> Float.round(2)
      }
    else
      _ -> nil
    end
  end

  # Prefill for the crop editor's inputs — sensible neutral when uncropped.
  defp crop_part(value, part) do
    default = %{"x" => 50, "y" => 50, "zoom" => 1}
    get_in(value, ["crop", part]) || default[part]
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp upload_failure(:too_large), do: "That file is over #{Assets.max_bytes()} bytes"

  defp upload_failure(:unsupported_type),
    do: "That file isn't a supported image (png/jpg/webp/gif)"

  defp upload_failure({:storage_failed, detail}),
    do: "Couldn't store the image (#{inspect(detail)}) — storage may be misconfigured; try again"

  defp upload_failure(reason), do: "Upload failed: #{inspect(reason)}"

  defp upload_error_msg(:too_large), do: "file is too large (max 5MB)"
  defp upload_error_msg(:not_accepted), do: "not an accepted image type"
  defp upload_error_msg(:too_many_files), do: "one image at a time"
  defp upload_error_msg(other), do: "upload error: #{inspect(other)}"

  # Which parts this slide can gain: missing optional scalars + list appends
  # + an image (any layout can carry one).
  defp addable_parts(raw, index) do
    raw_slide = Enum.at(raw["slides"], index) || %{}
    layout = raw_slide["layout"]

    # Media slides may carry an app-managed image too — it's the only way to
    # put a GENERATED image on one (media "src" is a raw URL the generator
    # never writes), and the escape hatch when a src link has died.
    image =
      if Map.has_key?(raw_slide, "image"),
        do: [],
        else: [{"image", "image"}]

    scalars =
      (~w(kicker footnote) ++ Map.get(@addable_scalars, layout, []))
      |> Enum.reject(&Map.has_key?(raw_slide, &1))
      |> Enum.map(&{&1, &1})

    lists =
      case Map.get(@addable_lists, layout) do
        nil ->
          []

        {"columns", label} ->
          if length(raw_slide["columns"] || []) < 2, do: [{label, "columns"}], else: []

        {key, label} ->
          [{label, key}]
      end

    image ++ scalars ++ lists
  end

  defp list_placeholder("columns", _slide), do: ["New bullet…"]
  defp list_placeholder("points", _slide), do: %{"label" => "NEW POINT", "body" => "Describe it…"}
  defp list_placeholder("steps", _slide), do: %{"actor" => "ACTOR", "body" => "What happens…"}
  defp list_placeholder("items", _slide), do: %{"q" => "New question?", "a" => "The answer…"}

  defp list_placeholder("rows", slide),
    do: List.duplicate("…", length(slide["columns"] || []))

  # Validate -> snapshot for undo -> conditional save -> tell other views.
  # A mutation that breaks the schema (deleting a required part, the last
  # slide) is rejected by the same validator that polices the model. A save
  # that lost a race (pipeline result, another tab) surfaces as a refresh +
  # message — the typed text survives in @edit_form, so recovery is saving
  # again.
  defp commit(socket, new_raw) do
    case Decks.parse(new_raw) do
      {:ok, _deck} ->
        case Decks.save(
               socket.assigns.deck_id,
               new_raw,
               socket.assigns.rev,
               socket.assigns.current_user.id
             ) do
          {:ok, rev} ->
            undo = Enum.take([socket.assigns.raw | socket.assigns.undo], @undo_depth)

            Phoenix.PubSub.broadcast_from(
              Uitstalling.PubSub,
              self(),
              socket.assigns.topic,
              :deck_updated
            )

            socket
            |> assign(undo: undo, rev: rev, selected: nil, edit_form: %{}, edit_error: nil)
            |> load_deck(new_raw)

          {:error, :stale} ->
            {fresh, rev} = Decks.checkout(socket.assigns.deck_id)

            socket
            |> assign(
              rev: rev,
              edit_error:
                "The deck changed while you edited — refreshed to the latest. " <>
                  "Your text is still in the editor; save again."
            )
            |> load_deck(fresh)
        end

      {:error, errors} ->
        assign(socket, edit_error: "Can't do that: #{hd(errors)}")
    end
  end

  # For raw this view just validated (commit/undo) — parse cannot fail.
  defp load_deck(socket, raw) do
    {:ok, deck} = Decks.parse(raw)
    index = min(socket.assigns.index, length(deck.slides) - 1)
    assign(socket, raw: raw, deck: deck, index: index, page_title: deck.title)
  end

  # For raw that arrived from outside this view (a :deck_updated broadcast) —
  # if it stopped validating (e.g. an asset vanished), keep showing the last
  # good state instead of crashing the LiveView.
  defp reload_deck(socket, raw) do
    case Decks.parse(raw) do
      {:ok, _deck} -> load_deck(socket, raw)
      {:error, errors} -> put_flash(socket, :error, "Deck update not shown: #{hd(errors)}")
    end
  end

  defp goto(socket, index, mode) do
    index = index |> max(0) |> min(length(socket.assigns.deck.slides) - 1)

    if mode == :broadcast do
      Phoenix.PubSub.broadcast_from(
        Uitstalling.PubSub,
        self(),
        socket.assigns.topic,
        {:goto, index}
      )
    end

    socket
    |> assign(index: index)
    |> push_event("goto_slide", %{index: index})
  end

  defp parse_index(socket, value) do
    case Integer.parse(to_string(value)) do
      {i, ""} when i >= 0 and i < length(socket.assigns.deck.slides) -> {:ok, i}
      _ -> {:noreply, socket}
    end
  end
end
