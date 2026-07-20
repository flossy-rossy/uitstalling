defmodule UitstallingWeb.DeckLive do
  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
  alias Uitstalling.Assets
  alias Uitstalling.Decks

  import UitstallingWeb.DeckComponents

  @undo_depth 20

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
         raw = Decks.load_raw!(deck_id),
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
          deck: deck,
          index: 0,
          can_edit: can_edit,
          edit_mode: false,
          selected: nil,
          regen: nil,
          pdf_modal: false,
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
    <main id="deck" phx-hook=".DeckNav">
      <.slide
        :for={{slide, i} <- Enum.with_index(@deck.slides)}
        deck={@deck}
        slide={slide}
        index={i}
        edit={@edit_mode}
        pending={pending_specs(@pending)}
      />

      <div class="fixed bottom-4 right-6 flex items-center gap-3">
        <button
          phx-click="open_pdf"
          class="font-mono text-xs text-zinc-400 bg-zinc-900/80 px-3 py-1.5 rounded ring-1 ring-zinc-700 hover:text-amber-400 hover:ring-amber-500 transition flex items-center gap-1.5"
          title="download this presentation as a PDF backup"
        >
          <.icon name="hero-arrow-down-tray" class="w-3.5 h-3.5" /> pdf
        </button>
        <.link
          navigate={@remote_path}
          class="font-mono text-xs text-zinc-400 bg-zinc-900/80 px-3 py-1.5 rounded ring-1 ring-zinc-700 hover:text-amber-400 hover:ring-amber-500 transition flex items-center gap-1.5"
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
          class="font-mono text-xs text-zinc-500 bg-zinc-900/80 px-3 py-1.5 rounded hover:text-amber-400 transition"
          title="Made with UIT"
        >
          <span class="text-amber-400 font-bold">8</span>stal
        </.link>
      </div>

      <div class="fixed bottom-4 left-6 flex items-center gap-2">
        <.link
          navigate={~p"/"}
          class="font-mono text-sm px-4 py-2 rounded-lg ring-1 bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-amber-400 transition"
        >
          ← decks
        </.link>
        <button
          :if={@can_edit}
          phx-click="toggle_edit"
          class={[
            "font-mono text-sm px-4 py-2 rounded-lg ring-1 transition",
            if(@edit_mode,
              do: "bg-amber-500 text-zinc-950 ring-amber-400 font-bold",
              else: "bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-amber-400"
            )
          ]}
        >
          {if @edit_mode, do: "✓ done", else: "✎ edit"}
        </button>
        <button
          :if={@can_edit and @edit_mode}
          phx-click="open_regen"
          class="font-mono text-sm px-4 py-2 rounded-lg ring-1 bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-amber-400 transition"
        >
          ↻ regenerate deck
        </button>
        <button
          :if={@undo != []}
          phx-click="undo"
          class="font-mono text-sm px-4 py-2 rounded-lg ring-1 bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-amber-400 transition"
        >
          ↶ undo ({length(@undo)})
        </button>
        <span
          :if={@pending != []}
          class="font-mono text-xs text-amber-400 bg-zinc-900/80 px-3 py-1.5 rounded flex items-center gap-2"
        >
          <span class="inline-block w-3 h-3 border-2 border-amber-400 border-t-transparent rounded-full animate-spin"></span>
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
          <p class="font-mono text-amber-400 text-xs tracking-wider mb-4">DOWNLOAD AS PDF</p>
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
            <%!-- phx-click only closes the modal — the anchor's default
                 navigation still fires and pulls the download. --%>
            <a
              href={~p"/deck/#{@deck_id}/pdf"}
              phx-click="close_pdf"
              class="px-5 py-2.5 rounded-lg bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold"
            >
              Download PDF
            </a>
          </div>
        </div>
      </div>

      <div
        :if={creating?(@pending)}
        class="fixed inset-0 z-[60] bg-zinc-950/95 flex items-center justify-center"
      >
        <div class="flex flex-col items-center gap-6 text-center px-8">
          <span class="inline-block w-12 h-12 border-4 border-amber-400 border-t-transparent rounded-full animate-spin"></span>
          <p class="font-mono text-amber-400 text-lg">generating your presentation…</p>
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
        <p class="font-mono text-amber-400 text-xs tracking-wider px-6 pt-6 pb-4 shrink-0">
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
                value={@value && @value["alt"]}
                class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-3 font-sans"
              />

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
                    checked={((@value && @value["treatment"]) || "side") == treatment}
                    class="text-amber-500 bg-zinc-950 border-zinc-700 focus:ring-amber-500"
                  /> {label}
                </label>
              </div>

              <div class="sticky bottom-0 mt-4 py-2 bg-zinc-900 flex justify-end">
                <button
                  type="submit"
                  class="px-5 py-2 rounded-lg bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold"
                >
                  Save image
                </button>
              </div>
            </form>

            <div :if={@kind == :image} class="mt-6 pt-4 border-t border-zinc-800">
              <p class="font-mono text-zinc-500 text-xs mb-2">
                {cond do
                  @gen_prompt -> "OR REGENERATE IT — tweak the prompt and go again"
                  @value -> "OR DESCRIBE A NEW ONE AND GENERATE"
                  true -> "OR DESCRIBE IT AND GENERATE"
                end}
              </p>
              <form id="image-gen-form" phx-submit="queue_image_gen" class="mt-2">
                <textarea
                  name="prompt"
                  rows="3"
                  placeholder="e.g. a clean isometric illustration of a phishing proxy between a user and a bank"
                  class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-4 font-sans"
                >{@gen_prompt}</textarea>
                <div class="mt-3 flex justify-end">
                  <button
                    type="submit"
                    class="px-6 py-2.5 rounded-lg bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold"
                  >
                    {if @gen_prompt, do: "Regenerate image", else: "Generate image"}
                  </button>
                </div>
              </form>
            </div>

            <%!-- Block level: edit the text exactly --%>
            <form :if={@kind not in [:agent_only, :image]} phx-submit="save_text">
              <%= case @kind do %>
                <% :scalar -> %>
                  <textarea
                    name="value"
                    rows={if @selected.block in ~w(heading kicker), do: 2, else: 4}
                    class={[
                      "w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-4",
                      if(@selected.block == "code", do: "font-mono", else: "font-sans")
                    ]}
                  >{@value}</textarea>
                <% :lines -> %>
                  <p class="font-mono text-zinc-500 text-xs mb-2">ONE BULLET PER LINE</p>
                  <textarea
                    name="value"
                    rows="6"
                    class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-4 font-sans"
                  >{Enum.join(@value, "\n")}</textarea>
                <% {:map, fields} -> %>
                  <div :for={field <- fields} class="mb-3">
                    <p class="font-mono text-zinc-500 text-xs mb-1 uppercase">{field}</p>
                    <textarea
                      name={field}
                      rows={if field in ~w(body a), do: 3, else: 1}
                      class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-3 font-sans"
                    >{@value[field]}</textarea>
                  </div>
              <% end %>
              <p class="mt-2 font-mono text-zinc-600 text-xs">
                markup: **strong** · ==accent== · ~~strike~~ · `code`
              </p>
              <div class="sticky bottom-0 mt-3 py-2 bg-zinc-900 flex justify-end">
                <button
                  type="submit"
                  class="px-5 py-2 rounded-lg bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold"
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
              <.agent_form placeholder={"e.g. reword this #{@selected.block} more simply"} />
            </div>
          <% else %>
            <%!-- Slide level: generation-oriented --%>
            <p class="font-mono text-zinc-500 text-xs mb-2">DESCRIBE THE CHANGES</p>
            <.agent_form placeholder="e.g. rework this slide around three punchy takeaways" />

            <div :if={@addable != []} class="mt-6">
              <p class="font-mono text-zinc-500 text-xs mb-2">ADD A PART</p>
              <div class="flex flex-wrap gap-2">
                <button
                  :for={{label, key} <- @addable}
                  phx-click="add_block"
                  phx-value-key={key}
                  class="px-4 py-2.5 rounded-lg font-mono text-sm ring-1 bg-zinc-950 text-zinc-400 ring-zinc-700 hover:text-amber-400 hover:ring-amber-500 transition"
                >
                  + {label}
                </button>
              </div>
              <p class="mt-2 font-mono text-zinc-600 text-xs">
                opens the new part's editor — type it exactly, or have it generated
              </p>
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
                      do: "bg-amber-500 text-zinc-950 ring-amber-400 font-bold",
                      else: "bg-zinc-950 text-zinc-400 ring-zinc-700 hover:text-amber-400"
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
              Delete {@selected.block}
            </button>
            <button
              :if={is_nil(@selected.block)}
              phx-click="delete_slide"
              class="px-5 py-2.5 rounded-lg text-red-400 ring-1 ring-red-900 hover:bg-red-950 font-mono text-sm"
            >
              Delete slide
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
        <p class="font-mono text-amber-400 text-xs tracking-wider px-6 pt-6 pb-4 shrink-0">
          REGENERATE THIS DECK
        </p>

        <form
          id="regen-form"
          phx-submit="queue_regen"
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
            class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-4 font-sans"
          >{@regen["prompt"]}</textarea>

          <p class="font-mono text-zinc-500 text-xs mt-4 mb-2">TONE &amp; AUDIENCE</p>
          <input
            type="text"
            name="voice"
            value={@regen["voice"]}
            placeholder="e.g. sharp and technical, for a security-savvy crowd"
            class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-3 font-sans"
          />

          <p class="font-mono text-zinc-500 text-xs mt-4 mb-2">
            RESEARCH / CONTEXT (optional{if @regen["research_filename"],
              do: " — from #{@regen["research_filename"]}"})
          </p>
          <textarea
            name="research"
            rows="6"
            placeholder="facts, numbers, names and quotes to ground the deck in"
            class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-4 font-sans text-sm"
          >{@regen["research"]}</textarea>

          <div class="sticky bottom-0 mt-4 py-2 bg-zinc-900 flex justify-end">
            <button
              type="submit"
              class="px-6 py-2.5 rounded-lg bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold"
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

  defp agent_form(assigns) do
    ~H"""
    <form phx-submit="queue_edit" class="mt-2">
      <textarea
        name="prompt"
        rows="3"
        placeholder={@placeholder}
        class="w-full bg-zinc-950 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-4 font-sans"
      ></textarea>
      <div class="mt-3 flex justify-end">
        <button
          type="submit"
          class="px-5 py-2 rounded-lg bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold"
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
      ["columns", _] -> :lines
      ["points", _] -> {:map, ~w(label body)}
      ["items", _] -> {:map, ~w(q a)}
      ["steps", _] -> {:map, ~w(actor body arrow_label)}
      # Table cells are structured (string | {text, tint}) — agent territory
      ["rows", _] -> :agent_only
      ["rows"] -> :agent_only
      [_scalar] -> :scalar
      # Anything else (incl. depth-3 paths) is edited via the agent for now
      _ -> :agent_only
    end
  end

  # ----- Navigation ---------------------------------------------------------

  def handle_event("nav", %{"dir" => dir}, socket) do
    {:noreply, goto(socket, socket.assigns.index + dir, :broadcast)}
  end

  # ----- PDF download -----------------------------------------------------------
  #
  # Anyone who can view can download. The video check runs here, on click —
  # not on every render: a deck with video gets a heads-up modal (those
  # slides degrade to a placeholder in the PDF); one without downloads
  # immediately. The response is an attachment, so the redirect leaves the
  # LiveView on screen.

  def handle_event("open_pdf", _params, socket) do
    if Decks.has_video?(socket.assigns.deck) do
      {:noreply, assign(socket, pdf_modal: true)}
    else
      {:noreply, redirect(socket, to: ~p"/deck/#{socket.assigns.deck_id}/pdf")}
    end
  end

  def handle_event("close_pdf", _params, socket) do
    {:noreply, assign(socket, pdf_modal: false)}
  end

  # ----- Edit mode ------------------------------------------------------------

  # AUTHORIZE every mutating event server-side — a client can push these
  # regardless of what the UI renders. Non-authors get a no-op.
  @edit_events ~w(toggle_edit select_block select_slide save_text set_size
                  add_block delete delete_slide undo queue_edit
                  save_image validate_image queue_image_gen
                  open_regen close_regen queue_regen
                  cancel_request dismiss_failure)

  def handle_event(event, _params, %{assigns: %{can_edit: false}} = socket)
      when event in @edit_events do
    {:noreply, socket}
  end

  def handle_event("toggle_edit", _params, socket) do
    {:noreply, assign(socket, edit_mode: !socket.assigns.edit_mode, selected: nil)}
  end

  def handle_event("select_block", %{"index" => index, "block" => block}, socket) do
    # `block` is client-supplied — a path the parser rejects is ignored
    # rather than crashing pattern matches downstream.
    with {:ok, index} <- parse_index(socket, index),
         {:ok, _parsed} <- Uitstalling.Decks.BlockPath.parse(block) do
      {:noreply, assign(socket, selected: %{index: index, block: block}, edit_error: nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("select_slide", %{"index" => index}, socket) do
    with {:ok, index} <- parse_index(socket, index) do
      {:noreply, assign(socket, selected: %{index: index, block: nil}, edit_error: nil)}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, selected: nil, edit_error: nil)}
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
      end

    {:noreply, commit(socket, new_raw)}
  end

  def handle_event("set_size", %{"size" => size}, socket) when size in ~w(sm md lg) do
    %{index: index} = socket.assigns.selected
    {:noreply, commit(socket, Decks.put_slide_key(socket.assigns.raw, index, "size", size))}
  end

  # Images have no text placeholder to commit — adding one just opens the
  # image editor; the slide changes only when an upload is saved.
  def handle_event("add_block", %{"key" => "image"}, socket) do
    %{index: index} = socket.assigns.selected
    {:noreply, assign(socket, selected: %{index: index, block: "image"}, edit_error: nil)}
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
        else: assign(socket, selected: %{index: index, block: new_path})

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    %{index: index, block: block} = socket.assigns.selected
    {:noreply, commit(socket, Decks.delete_block(socket.assigns.raw, index, block))}
  end

  # ----- Images (app-managed asset references) ----------------------------------

  def handle_event("validate_image", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("queue_image_gen", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    if prompt == "" do
      {:noreply, socket}
    else
      %{index: index} = socket.assigns.selected
      slide = Enum.at(socket.assigns.deck.slides, index)

      Decks.queue_request(%{
        "type" => "asset",
        "deck_id" => socket.assigns.deck_id,
        "slide_id" => slide.id,
        "block" => "image",
        "prompt" => prompt
      })

      Phoenix.PubSub.broadcast_from(
        Uitstalling.PubSub,
        self(),
        socket.assigns.topic,
        :queue_updated
      )

      Decks.DeckWorker.kick(socket.assigns.deck_id)

      {:noreply, socket |> assign(selected: nil) |> refresh_pending()}
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
        {:noreply, save_image_block(socket, index, asset.id, params)}

      {[{:error, reason}], _} ->
        {:noreply, assign(socket, edit_error: upload_failure(reason))}

      {[], %{"asset_id" => asset_id}} ->
        # No new file — just updating alt/treatment on the existing image
        {:noreply, save_image_block(socket, index, asset_id, params)}

      {[], nil} ->
        {:noreply, assign(socket, edit_error: "Choose an image file first")}
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
        Decks.save!(socket.assigns.deck_id, previous)

        Phoenix.PubSub.broadcast_from(
          Uitstalling.PubSub,
          self(),
          socket.assigns.topic,
          :deck_updated
        )

        {:noreply, socket |> assign(undo: rest) |> load_deck(previous)}
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

    {:noreply, assign(socket, regen: base, selected: nil)}
  end

  def handle_event("close_regen", _params, socket) do
    {:noreply, assign(socket, regen: nil)}
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
      {:noreply, assign(socket, selected: nil)}
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
       |> assign(selected: nil)
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
  def handle_info(:deck_updated, socket) do
    {:noreply,
     socket |> reload_deck(Decks.load_raw!(socket.assigns.deck_id)) |> assign(selected: nil)}
  end

  def handle_info(:queue_updated, socket) do
    {:noreply, refresh_pending(socket)}
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

    commit(socket, Decks.put_block(socket.assigns.raw, index, "image", image))
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

    image =
      if Map.has_key?(raw_slide, "image") or layout == "media",
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

  # Validate -> snapshot for undo -> persist -> tell other views. A mutation
  # that breaks the schema (deleting a required part, the last slide) is
  # rejected by the same validator that polices the model.
  defp commit(socket, new_raw) do
    case Decks.parse(new_raw) do
      {:ok, _deck} ->
        undo = Enum.take([socket.assigns.raw | socket.assigns.undo], @undo_depth)
        Decks.save!(socket.assigns.deck_id, new_raw)

        Phoenix.PubSub.broadcast_from(
          Uitstalling.PubSub,
          self(),
          socket.assigns.topic,
          :deck_updated
        )

        socket
        |> assign(undo: undo, selected: nil, edit_error: nil)
        |> load_deck(new_raw)

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
