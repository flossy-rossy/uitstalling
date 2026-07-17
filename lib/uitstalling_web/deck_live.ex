defmodule UitstallingWeb.DeckLive do
  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
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

  def mount(%{"id" => deck_id}, _session, socket) do
    if Decks.exists?(deck_id) do
      raw = Decks.load_raw!(deck_id)
      {:ok, deck} = Decks.parse(raw)
      # Presenting is public-by-link; only an authorized author who owns the
      # deck may edit.
      user = socket.assigns.current_user
      can_edit = Accounts.can_author?(user) and Decks.owned_by?(deck_id, user.id)

      socket =
        assign(socket,
          deck_id: deck_id,
          topic: "deck:#{deck_id}",
          page_title: deck.title,
          raw: raw,
          deck: deck,
          index: 0,
          can_edit: can_edit,
          edit_mode: false,
          selected: nil,
          undo: [],
          edit_error: nil,
          pending: []
        )

      socket =
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Uitstalling.PubSub, socket.assigns.topic)
          refresh_pending(socket)
        else
          socket
        end

      {:ok, socket}
    else
      {:ok, socket |> put_flash(:error, "No such presentation") |> redirect(to: ~p"/")}
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
          class="font-mono text-xs px-3 py-1.5 rounded ring-1 bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-amber-400 transition"
        >
          ← decks
        </.link>
        <button
          :if={@can_edit}
          phx-click="toggle_edit"
          class={[
            "font-mono text-xs px-3 py-1.5 rounded ring-1 transition",
            if(@edit_mode,
              do: "bg-amber-500 text-zinc-950 ring-amber-400 font-bold",
              else: "bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-amber-400"
            )
          ]}
        >
          {if @edit_mode, do: "✓ done", else: "✎ edit"}
        </button>
        <button
          :if={@undo != []}
          phx-click="undo"
          class="font-mono text-xs px-3 py-1.5 rounded ring-1 bg-zinc-900/80 text-zinc-400 ring-zinc-700 hover:text-amber-400 transition"
        >
          ↶ undo ({length(@undo)})
        </button>
        <span
          :if={@pending != []}
          class="font-mono text-xs text-amber-400 bg-zinc-900/80 px-3 py-1.5 rounded flex items-center gap-2"
        >
          <span class="inline-block w-3 h-3 border-2 border-amber-400 border-t-transparent rounded-full animate-spin"></span>
          {length(@pending)} generating
        </span>
      </div>

      <.options_panel
        :if={@selected}
        selected={@selected}
        slide={Enum.at(@deck.slides, @selected.index)}
        value={@selected.block && Decks.get_block(@raw, @selected.index, @selected.block)}
        addable={addable_parts(@raw, @selected.index)}
        edit_error={@edit_error}
      />

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

  attr :selected, :map, required: true
  attr :slide, Uitstalling.Decks.Slide, required: true
  attr :value, :any, default: nil
  attr :addable, :list, default: []
  attr :edit_error, :string, default: nil

  defp options_panel(assigns) do
    assigns = assign(assigns, :kind, assigns.selected.block && block_kind(assigns.selected.block))

    ~H"""
    <div class="fixed inset-0 z-50 bg-zinc-950/80 flex items-center justify-center p-6">
      <div class="w-full max-w-xl bg-zinc-900 ring-1 ring-zinc-700 rounded-xl p-6 max-h-[90dvh] overflow-y-auto">
        <p class="font-mono text-amber-400 text-xs tracking-wider mb-4">
          EDIT SLIDE {@selected.index + 1} · {@slide.layout}
          <span :if={@selected.block} class="text-zinc-400">· {@selected.block}</span>
        </p>

        <%= if @selected.block do %>
          <%!-- Block level: edit the text exactly --%>
          <form :if={@kind != :agent_only} phx-submit="save_text">
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
            <div class="mt-3 flex justify-end">
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

          <details class={@kind != :agent_only && "mt-4"} open={@kind == :agent_only}>
            <summary class="font-mono text-zinc-500 text-xs cursor-pointer hover:text-amber-400">
              → OR ASK THE AGENT
            </summary>
            <.agent_form placeholder={"e.g. reword this #{@selected.block} more simply"} />
          </details>
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
                class="px-3 py-1.5 rounded-lg font-mono text-xs ring-1 bg-zinc-950 text-zinc-400 ring-zinc-700 hover:text-amber-400 hover:ring-amber-500 transition"
              >
                + {label}
              </button>
            </div>
            <p class="mt-2 font-mono text-zinc-600 text-xs">
              adds a placeholder, then you write it — or ask the agent from its editor
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

        <div class="mt-6 pt-4 border-t border-zinc-800 flex items-center justify-between">
          <div class="flex gap-3">
            <button
              :if={@selected.block}
              phx-click="delete"
              class="px-4 py-2 rounded-lg text-red-400 ring-1 ring-red-900 hover:bg-red-950 font-mono text-sm"
            >
              Delete {@selected.block}
            </button>
            <button
              :if={is_nil(@selected.block)}
              phx-click="delete_slide"
              class="px-4 py-2 rounded-lg text-red-400 ring-1 ring-red-900 hover:bg-red-950 font-mono text-sm"
            >
              Delete slide
            </button>
          </div>
          <button
            phx-click="cancel_edit"
            class="px-4 py-2 rounded-lg text-zinc-400 hover:text-zinc-200"
          >
            Close
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :placeholder, :string, required: true

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
      ["columns", _] -> :lines
      ["points", _] -> {:map, ~w(label body)}
      ["items", _] -> {:map, ~w(q a)}
      ["steps", _] -> {:map, ~w(actor body arrow_label)}
      # Table cells are structured (string | {text, tint}) — agent territory
      ["rows", _] -> :agent_only
      ["rows"] -> :agent_only
      [_scalar] -> :scalar
    end
  end

  # ----- Navigation ---------------------------------------------------------

  def handle_event("nav", %{"dir" => dir}, socket) do
    {:noreply, goto(socket, socket.assigns.index + dir, :broadcast)}
  end

  # ----- Edit mode ------------------------------------------------------------

  # AUTHORIZE every mutating event server-side — a client can push these
  # regardless of what the UI renders. Non-authors get a no-op.
  @edit_events ~w(toggle_edit select_block select_slide save_text set_size
                  add_block delete delete_slide undo queue_edit)

  def handle_event(event, _params, %{assigns: %{can_edit: false}} = socket)
      when event in @edit_events do
    {:noreply, socket}
  end

  def handle_event("toggle_edit", _params, socket) do
    {:noreply, assign(socket, edit_mode: !socket.assigns.edit_mode, selected: nil)}
  end

  def handle_event("select_block", %{"index" => index, "block" => block}, socket) do
    with {:ok, index} <- parse_index(socket, index) do
      {:noreply, assign(socket, selected: %{index: index, block: block}, edit_error: nil)}
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

      Decks.Pipeline.kick()

      {:noreply,
       socket
       |> assign(selected: nil)
       |> refresh_pending()}
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
     socket |> load_deck(Decks.load_raw!(socket.assigns.deck_id)) |> assign(selected: nil)}
  end

  def handle_info(:queue_updated, socket) do
    {:noreply, refresh_pending(socket)}
  end

  # ----- Helpers ----------------------------------------------------------------

  defp refresh_pending(socket) do
    pending =
      Enum.filter(Decks.pending_requests(), &(&1["deck_id"] == socket.assigns.deck_id))

    assign(socket, pending: pending)
  end

  defp pending_specs(pending) do
    for %{"slide_id" => slide_id} = request <- pending, request["type"] != "create" do
      {slide_id, request["block"]}
    end
  end

  defp creating?(pending), do: Enum.any?(pending, &(&1["type"] == "create"))

  # Which parts this slide can gain: missing optional scalars + list appends.
  defp addable_parts(raw, index) do
    raw_slide = Enum.at(raw["slides"], index) || %{}
    layout = raw_slide["layout"]

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

    scalars ++ lists
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

  defp load_deck(socket, raw) do
    {:ok, deck} = Decks.parse(raw)
    index = min(socket.assigns.index, length(deck.slides) - 1)
    assign(socket, raw: raw, deck: deck, index: index, page_title: deck.title)
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
