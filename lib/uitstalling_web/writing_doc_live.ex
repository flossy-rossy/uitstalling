defmodule UitstallingWeb.WritingDocLive do
  @moduledoc """
  The writing editor: one doc (chapter, plan map, or element) as a column of
  block editors that read like a page. Every change is an op batch through
  `Writing.apply_ops/6` — CAS'd, event-logged, undoable.

  A prose block holds MANY paragraphs (newline-separated). Enter is just a
  newline in the textarea — client-side, no op, no event: pressing Return a
  hundred times while drafting must not append a hundred events. New blocks
  are for real structure only — a scene break, a heading, a new section —
  added deliberately from the + bar. So ops fire on the debounced text save
  (per typing pause / on blur) and on explicit structure, never per keystroke.
  Fine-grained undo while writing is the browser's own textarea undo; the
  event log is the coarser "restore this version" history.

  Typing stays client-side: block editors are `phx-update="ignore"` (a
  colocated hook debounces saves and flushes on blur), so routine commits
  never touch the DOM the writer is typing in. Structural changes
  (add/retype/delete/undo, or another session's write) bump `@bump`, part of
  every block's DOM id — the blocks remount with committed truth and the hook
  re-focuses where the writer expects to be.
  """

  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
  alias Uitstalling.Writing
  alias Uitstalling.Writing.Op.{DeleteField, InsertBlock, RemoveBlock, SetField}
  alias Uitstalling.Writing.ProjectServer
  alias UitstallingWeb.WritingComponents

  import UitstallingWeb.WritingComponents, only: [type_dropdown: 1, loading: 1]

  def mount(%{"project_id" => project_id, "doc_id" => doc_id}, _session, socket) do
    user = socket.assigns.current_user

    cond do
      is_nil(user) ->
        {:ok,
         socket
         |> put_flash(:error, "Sign in to write")
         |> redirect(to: ~p"/auth/login?return_to=#{"/write/#{project_id}/#{doc_id}"}")}

      not (Accounts.can_author?(user) and Writing.owned_by?(project_id, user.id)) ->
        {:ok, socket |> put_flash(:error, "No such document") |> redirect(to: ~p"/write")}

      true ->
        # Cheap now: project row (theme/font for the frame) and the doc row's
        # plaintext columns (kind/element_type drive the palette). The
        # decrypt-heavy body, title, links and map stream in from the
        # ProjectServer cache via start_async.
        project = Writing.get_project!(project_id, user.id)
        doc = Writing.get_doc!(project, doc_id)
        topic = "writing:#{doc_id}"

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Uitstalling.PubSub, topic)
        end

        {:ok,
         socket
         |> assign(
           project: project,
           project_title: nil,
           doc_id: doc_id,
           kind: doc.kind,
           element_type: doc.element_type,
           topic: topic,
           loaded: false,
           title: nil,
           page_title: "…",
           raw: %{"blocks" => []},
           seq: 0,
           words: 0,
           linked: [],
           map_docs: %{},
           map_edges: [],
           active_types: Writing.active_element_types(user),
           registry: Writing.element_type_registry(user),
           tag_picker: false,
           tag_options: [],
           tag_type: "character",
           tag_type_menu: false,
           portrait_target: nil,
           bump: 0,
           menu: nil,
           renaming: false,
           edit_error: nil
         )
         |> allow_upload(:portrait,
           accept: ~w(.png .jpg .jpeg .webp),
           max_entries: 1,
           max_file_size: 3_000_000
         )
         |> start_async(:load, fn ->
           {raw, seq, title} = ProjectServer.checkout_doc(project_id, doc_id)

           %{
             raw: raw,
             seq: seq,
             title: title,
             project_title: ProjectServer.title(project_id),
             linked: Writing.linked_docs(project, doc_id),
             map: map_data(project, doc_id, doc.kind)
           }
         end)}
    end
  end

  def handle_async(:load, {:ok, data}, socket) do
    {:noreply,
     assign(socket,
       loaded: true,
       raw: data.raw,
       seq: data.seq,
       title: data.title,
       page_title: data.title,
       project_title: data.project_title,
       words: Writing.count_words(data.raw),
       linked: data.linked,
       map_docs: data.map.docs,
       map_edges: data.map.edges
     )}
  end

  def handle_async(:load, {:exit, reason}, socket) do
    require Logger
    Logger.error("writing doc load failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> put_flash(:error, "Couldn't open that document — try again.")
     |> redirect(to: ~p"/write/#{socket.assigns.project.id}")}
  end

  # ----- Text edits (from the block hook) ---------------------------------------

  def handle_event("save_block", %{"id" => id, "field" => field, "value" => value}, socket)
      when is_binary(value) do
    with %{} = block <- find_block(socket.assigns.raw, id),
         true <- field in (Writing.block_keys(block["type"]) || []),
         false <- block[field] == value do
      {:noreply, commit(socket, [%SetField{block: id, field: field, value: value}])}
    else
      _ -> {:noreply, socket}
    end
  end

  # ----- Structure (block menu / add bar) ------------------------------------------

  def handle_event("add_block", %{"type" => type}, socket) do
    if type in palette(socket.assigns.kind, socket.assigns.element_type) do
      # Caret to the block just appended.
      {:noreply,
       commit(socket, [%InsertBlock{block: default_block(type)}],
         bump: true,
         focus: &{List.last(&1["blocks"])["id"], 0}
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_type", %{"id" => id, "type" => type}, socket) do
    with true <-
           type in (palette(socket.assigns.kind, socket.assigns.element_type) -- ~w(portrait)),
         %{} = block <- find_block(socket.assigns.raw, id),
         false <- block["type"] == type do
      new_keys = Writing.block_keys(type)
      old_keys = Map.keys(block) -- ~w(id type)

      ops =
        [%SetField{block: id, field: "type", value: type}] ++
          Enum.map(old_keys -- new_keys, &%DeleteField{block: id, field: &1}) ++
          Enum.map(
            Writing.block_required(type) -- old_keys,
            &%SetField{block: id, field: &1, value: ""}
          )

      {:noreply, commit(socket, ops, bump: true)}
    else
      _ -> {:noreply, assign(socket, menu: nil)}
    end
  end

  def handle_event("delete_block", %{"id" => id}, socket) do
    {:noreply, commit(socket, [%RemoveBlock{block: id}], bump: true)}
  end

  def handle_event("toggle_menu", %{"id" => id}, socket) do
    {:noreply, assign(socket, menu: if(socket.assigns.menu == id, do: nil, else: id))}
  end

  def handle_event("close_menu", _params, socket) do
    {:noreply, assign(socket, menu: nil)}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, edit_error: nil)}
  end

  # ----- Tags (plan links) ---------------------------------------------------------
  #
  # Chapters tag the elements that appear in them; element pages link other
  # elements (and show which chapters feature them). One link table both ways.

  def handle_event("toggle_tag_picker", _params, socket) do
    if socket.assigns.tag_picker do
      {:noreply, assign(socket, tag_picker: false, tag_type_menu: false)}
    else
      {:noreply, assign(socket, tag_picker: true, tag_options: tag_options(socket))}
    end
  end

  def handle_event("close_tag_picker", _params, socket) do
    {:noreply, assign(socket, tag_picker: false, tag_type_menu: false)}
  end

  def handle_event("toggle_tag_type_menu", _params, socket) do
    {:noreply, assign(socket, tag_type_menu: not socket.assigns.tag_type_menu)}
  end

  def handle_event("pick_tag_type", %{"type" => type}, socket) do
    if type in Enum.map(socket.assigns.active_types, & &1.key) do
      {:noreply, assign(socket, tag_type: type, tag_type_menu: false)}
    else
      {:noreply, socket}
    end
  end

  # Adding a tag closes the picker — tagging is usually one element at a
  # time, and a lingering panel reads as "something is still open".
  def handle_event("add_tag", %{"id" => other_id}, socket) do
    case Writing.link(socket.assigns.project, socket.assigns.doc_id, other_id) do
      :ok -> {:noreply, socket |> reload_links() |> assign(tag_picker: false)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("remove_tag", %{"id" => other_id}, socket) do
    :ok = Writing.unlink(socket.assigns.project, socket.assigns.doc_id, other_id)
    {:noreply, reload_links(socket)}
  end

  # ----- Portraits (encrypted upload) --------------------------------------------------

  def handle_event("start_portrait", %{"id" => id}, socket) do
    {:noreply, assign(socket, portrait_target: id)}
  end

  def handle_event("cancel_portrait", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.portrait.entries, socket, fn entry, socket ->
        cancel_upload(socket, :portrait, entry.ref)
      end)

    {:noreply, assign(socket, portrait_target: nil)}
  end

  def handle_event("validate_portrait", _params, socket), do: {:noreply, socket}

  def handle_event("save_portrait", %{"block" => id}, socket) do
    bytes =
      consume_uploaded_entries(socket, :portrait, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    with [binary] <- bytes,
         {:ok, image_id} <- Writing.put_image(socket.assigns.project, binary) do
      socket =
        socket
        |> commit([%SetField{block: id, field: "image", value: image_id}], bump: true)
        |> assign(portrait_target: nil)

      {:noreply, socket}
    else
      [] -> {:noreply, socket}
      {:error, message} -> {:noreply, assign(socket, edit_error: message, portrait_target: nil)}
    end
  end

  def handle_event("remove_portrait", %{"id" => id}, socket) do
    {:noreply, commit(socket, [%DeleteField{block: id, field: "image"}], bump: true)}
  end

  # ----- Plan map (kind "planning": placed dots + connections) ---------------------------

  def handle_event("map_add", %{"doc" => other_id}, socket) do
    placed = placed_doc_ids(socket.assigns.raw)

    if Map.has_key?(socket.assigns.map_docs, other_id) and other_id not in placed do
      {:noreply,
       commit(socket, [%InsertBlock{block: new_node(other_id, length(placed))}], bump: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("map_create", %{"name" => name}, socket) do
    %{project: project, doc_id: doc_id, kind: kind, tag_type: type} = socket.assigns

    case ProjectServer.create_element(project.id, type, name) do
      {:ok, element_id} ->
        placed = placed_doc_ids(socket.assigns.raw)
        map = map_data(project, doc_id, kind)

        socket =
          socket
          |> assign(map_docs: map.docs, map_edges: map.edges)
          |> commit([%InsertBlock{block: new_node(element_id, length(placed))}], bump: true)

        {:noreply, socket}

      {:error, [error | _]} ->
        {:noreply, assign(socket, edit_error: error)}
    end
  end

  def handle_event("map_move", %{"id" => id, "x" => x, "y" => y}, socket)
      when is_number(x) and is_number(y) do
    with %{"type" => "node"} <- find_block(socket.assigns.raw, id) do
      ops = [
        %SetField{block: id, field: "x", value: clamp(x)},
        %SetField{block: id, field: "y", value: clamp(y)}
      ]

      # No bump: the drag already moved the dot; a remount would stutter.
      {:noreply, commit(socket, ops)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("map_connect", %{"a" => a, "b" => b}, socket) do
    %{project: project, doc_id: doc_id, kind: kind} = socket.assigns

    with %{"type" => "node", "doc" => doc_a} <- find_block(socket.assigns.raw, a),
         %{"type" => "node", "doc" => doc_b} <- find_block(socket.assigns.raw, b),
         :ok <- Writing.link(project, doc_a, doc_b) do
      map = map_data(project, doc_id, kind)

      {:noreply,
       assign(socket, map_docs: map.docs, map_edges: map.edges, bump: socket.assigns.bump + 1)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("map_remove", %{"id" => id}, socket) do
    {:noreply, commit(socket, [%RemoveBlock{block: id}], bump: true)}
  end

  def handle_event("map_open", %{"doc" => doc_id}, socket) do
    if Map.has_key?(socket.assigns.map_docs, doc_id) do
      {:noreply, push_navigate(socket, to: ~p"/write/#{socket.assigns.project.id}/#{doc_id}")}
    else
      {:noreply, socket}
    end
  end

  # ----- Undo (the event log, not a socket stack) --------------------------------------

  def handle_event("undo", _params, socket) do
    %{project: project, doc_id: doc_id, seq: seq} = socket.assigns

    case ProjectServer.undo(project.id, doc_id, seq, socket.assigns.current_user.id) do
      {:ok, raw, seq} ->
        broadcast_update(socket)
        {:noreply, refresh(socket, raw, seq)}

      {:error, :nothing_to_undo} ->
        {:noreply, socket}

      {:error, :stale} ->
        {:noreply, reload_stale(socket)}

      {:error, [error | _]} ->
        {:noreply, assign(socket, edit_error: "Can't undo that: #{error}")}
    end
  end

  # ----- Title ---------------------------------------------------------------------------

  def handle_event("start_rename", _params, socket) do
    {:noreply, assign(socket, renaming: true)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, renaming: false)}
  end

  def handle_event("save_title", %{"title" => title}, socket) do
    %{project: project, doc_id: doc_id, seq: seq} = socket.assigns

    case ProjectServer.rename_doc(project.id, doc_id, title, seq, socket.assigns.current_user.id) do
      {:ok, title, seq} ->
        broadcast_update(socket)
        {:noreply, assign(socket, title: title, page_title: title, seq: seq, renaming: false)}

      {:error, :stale} ->
        {:noreply, reload_stale(socket)}

      {:error, _} ->
        {:noreply, assign(socket, renaming: false)}
    end
  end

  # Another session (or a future shared commenter) changed the doc.
  def handle_info(:doc_updated, socket) do
    %{project: project, doc_id: doc_id, kind: kind} = socket.assigns
    {raw, seq, title} = ProjectServer.checkout_doc(project.id, doc_id)
    map = map_data(project, doc_id, kind)

    {:noreply,
     socket
     |> assign(title: title, page_title: title, map_docs: map.docs, map_edges: map.edges)
     |> refresh(raw, seq)}
  end

  # ----- Commit plumbing --------------------------------------------------------------------

  # Apply an op batch and return the updated socket (pipeable). `:bump`
  # remounts the block DOM (structural edits); `:focus` is a `raw -> {block,
  # pos}` resolver run only on success, against the committed document, so
  # the caret lands where the edit put it.
  defp commit(socket, ops, opts \\ []) do
    %{project: project, doc_id: doc_id, seq: seq} = socket.assigns

    case ProjectServer.apply_ops(project.id, doc_id, ops, seq, socket.assigns.current_user.id) do
      {:ok, raw, seq} ->
        socket
        |> broadcast_update()
        |> then(fn socket ->
          if opts[:bump],
            do: refresh(socket, raw, seq),
            else: assign(socket, raw: raw, seq: seq, words: Writing.count_words(raw), menu: nil)
        end)
        |> maybe_focus(opts[:focus], raw)

      {:error, :stale} ->
        reload_stale(socket)

      {:error, [error | _]} ->
        assign(socket, edit_error: "Can't do that: #{error}")
    end
  end

  defp maybe_focus(socket, nil, _raw), do: socket

  defp maybe_focus(socket, resolve, raw) do
    case resolve.(raw) do
      {block_id, pos} when is_binary(block_id) -> push_focus(socket, block_id, pos)
      _ -> socket
    end
  end

  # Structural refresh: blocks remount (bump is in their DOM ids) so the
  # client shows exactly the committed truth.
  defp refresh(socket, raw, seq) do
    assign(socket,
      raw: raw,
      seq: seq,
      words: Writing.count_words(raw),
      bump: socket.assigns.bump + 1,
      menu: nil,
      edit_error: nil
    )
  end

  defp reload_stale(socket) do
    {raw, seq, title} =
      ProjectServer.checkout_doc(socket.assigns.project.id, socket.assigns.doc_id)

    socket
    |> assign(title: title, page_title: title)
    |> refresh(raw, seq)
    |> assign(edit_error: "The document changed underneath — refreshed to the latest.")
  end

  defp broadcast_update(socket) do
    Phoenix.PubSub.broadcast_from(Uitstalling.PubSub, self(), socket.assigns.topic, :doc_updated)
    socket
  end

  defp push_focus(socket, block_id, pos),
    do: push_event(socket, "focus_block", %{id: block_id, pos: pos})

  defp reload_links(socket) do
    linked = Writing.linked_docs(socket.assigns.project, socket.assigns.doc_id)
    options = if socket.assigns.tag_picker, do: tag_options(socket, linked), else: []
    assign(socket, linked: linked, tag_options: options)
  end

  # What the picker offers: elements always; chapters too when this doc is
  # itself an element (so "appears in chapter …" can be added from either
  # side). Never self, never already-linked.
  defp tag_options(socket, linked \\ nil) do
    %{project: project, doc_id: doc_id, kind: kind} = socket.assigns
    linked = linked || socket.assigns.linked
    linked_ids = MapSet.new(linked, & &1.id)

    project.id
    |> ProjectServer.list_docs()
    |> Enum.filter(fn doc ->
      doc.id != doc_id and not MapSet.member?(linked_ids, doc.id) and
        (doc.kind == "element" or (kind == "element" and doc.kind == "chapter"))
    end)
  end

  defp find_block(raw, id), do: Enum.find(raw["blocks"], &(&1["id"] == id))

  defp default_block("scene_break"), do: %{"type" => "scene_break"}
  defp default_block("character"), do: %{"type" => "character", "name" => "", "text" => ""}
  defp default_block("beat"), do: %{"type" => "beat", "label" => "", "text" => ""}
  defp default_block("field"), do: %{"type" => "field", "label" => "", "text" => ""}
  defp default_block("portrait"), do: %{"type" => "portrait"}
  defp default_block(type), do: %{"type" => type, "text" => ""}

  # The add-bar / retype catalog for this doc. Characters keep a profile
  # palette (no headings or scene breaks); plan-map notes exclude the
  # canvas-only node blocks (those come from the map palette).
  defp palette("element", "character"), do: ~w(field paragraph portrait)
  defp palette("element", _type), do: ~w(field paragraph heading beat)
  defp palette("planning", _type), do: Writing.block_types("planning") -- ~w(node)
  defp palette(kind, _type), do: Writing.block_types(kind)

  defp type_label("paragraph"), do: "¶ paragraph"
  defp type_label("heading"), do: "H heading"
  defp type_label("scene_break"), do: "✳ scene break"
  defp type_label("epigraph"), do: "❝ epigraph"
  defp type_label("character"), do: "☺ character"
  defp type_label("beat"), do: "→ beat"
  defp type_label("field"), do: "☰ field"
  defp type_label("portrait"), do: "◉ portrait"

  defp upload_error_label(:too_large), do: "too large (3 MB max)"
  defp upload_error_label(:not_accepted), do: "not an image"
  defp upload_error_label(other), do: to_string(other)

  # ----- Plan-map plumbing ---------------------------------------------------------------

  # Titles/types (keyed by id) for every doc a map dot could reference, plus
  # the project's link edges. Only plan maps pay for this; other kinds get an
  # empty map. Docs come from the ProjectServer cache; edges read the links.
  defp map_data(project, doc_id, "planning") do
    docs =
      project.id
      |> ProjectServer.list_docs()
      |> Enum.reject(&(&1.id == doc_id))
      |> Map.new(fn doc -> {doc.id, doc} end)

    %{docs: docs, edges: Writing.graph(project).edges}
  end

  defp map_data(_project, _doc_id, _kind), do: %{docs: %{}, edges: []}

  defp placed_doc_ids(raw) do
    for %{"type" => "node", "doc" => doc} <- raw["blocks"], do: doc
  end

  # New dots land near the middle, fanned out so they don't stack.
  defp new_node(doc_id, count) do
    %{
      "type" => "node",
      "doc" => doc_id,
      "x" => 500 + rem(count, 5) * 60 - 120,
      "y" => 280 + div(count, 5) * 70
    }
  end

  defp clamp(value), do: value |> max(0) |> min(100_000) |> Float.round(1)

  # Chips under the canvas: what's placed (with its block id, for removal)
  # and which elements are still on the shelf.
  defp assign_map_chips(%{kind: "planning"} = assigns) do
    placed =
      for %{"type" => "node", "id" => id, "doc" => doc_id} <- assigns.raw["blocks"],
          doc = assigns.map_docs[doc_id],
          do: {id, doc}

    placed_docs = MapSet.new(placed, fn {_id, doc} -> doc.id end)

    unplaced =
      assigns.map_docs
      |> Enum.filter(fn {id, doc} ->
        doc.kind == "element" and not MapSet.member?(placed_docs, id)
      end)
      |> Enum.sort_by(fn {_id, doc} -> {doc.element_type, doc.title} end)

    assign(assigns, placed: placed, unplaced: unplaced)
  end

  defp assign_map_chips(assigns), do: assign(assigns, placed: [], unplaced: [])

  # What the canvas hook draws: placed dots (with titles/colors resolved)
  # and the link edges between docs that are both on this map.
  defp canvas_payload(raw, map_docs, map_edges, theme, registry) do
    nodes =
      for %{"type" => "node", "id" => id, "doc" => doc_id, "x" => x, "y" => y} <- raw["blocks"],
          doc = map_docs[doc_id] do
        type = doc.element_type || doc.kind

        %{
          block: id,
          doc: doc_id,
          title: doc.title,
          type: type,
          color: WritingComponents.element_hex(registry, type),
          x: x,
          y: y
        }
      end

    on_map = MapSet.new(nodes, & &1.doc)

    edges =
      for %{source: s, target: t} <- map_edges,
          MapSet.member?(on_map, s) and MapSet.member?(on_map, t) do
        %{a: s, b: t}
      end

    Jason.encode!(%{
      nodes: nodes,
      edges: edges,
      ink: WritingComponents.map_colors(theme).ink,
      edgeColor: WritingComponents.map_colors(theme).edge
    })
  end

  # ----- Render -------------------------------------------------------------------------------

  def render(assigns) do
    assigns =
      assigns
      |> assign(:palette, WritingComponents.page_theme(assigns.project.theme))
      |> assign(:font, WritingComponents.font_class(assigns.project.font))
      |> assign_map_chips()

    ~H"""
    <main
      id="writing-doc"
      phx-hook=".WritingDocNav"
      class={["min-h-dvh", @font, @palette.bg, @palette.ink]}
    >
      <.loading :if={not @loaded} palette={@palette} label="opening…" />

      <header
        :if={@loaded}
        class={[
          "fixed top-0 inset-x-0 z-40 border-b backdrop-blur",
          @palette.bg,
          @palette.rule
        ]}
      >
        <div class="max-w-2xl mx-auto px-6 py-3 flex items-center gap-4">
          <.link
            navigate={~p"/write/#{@project.id}"}
            class={["font-mono text-xs shrink-0", @palette.muted, "hover:underline"]}
          >
            ← {@project_title}
          </.link>

          <div class="flex-1 min-w-0 text-center">
            <button
              :if={not @renaming}
              phx-click="start_rename"
              class="font-semibold truncate max-w-full hover:underline decoration-1 underline-offset-4"
              title="Rename"
            >
              {@title}
              <span
                :if={@element_type}
                class={[
                  "ml-2 rounded-full ring-1 px-2 py-0.5 font-mono text-[10px] uppercase tracking-wider",
                  WritingComponents.element_chip(@registry, @element_type, @palette.light)
                ]}
              >
                {@element_type}
              </span>
            </button>
            <form :if={@renaming} phx-submit="save_title" class="flex gap-2 justify-center">
              <input
                type="text"
                name="title"
                value={@title}
                required
                autofocus
                autocomplete="off"
                class={[
                  "rounded px-2 py-1 bg-transparent border text-sm",
                  @palette.rule,
                  "focus:outline-none"
                ]}
              />
              <button type="submit" class={["font-mono text-xs", @palette.accent]}>save</button>
              <button
                type="button"
                phx-click="cancel_rename"
                class={["font-mono text-xs", @palette.faint]}
              >
                ✕
              </button>
            </form>
          </div>

          <div class="flex items-center gap-4 shrink-0">
            <button
              phx-click="undo"
              class={["font-mono text-xs", @palette.muted, "hover:opacity-70"]}
              title="Undo (event-logged — survives refresh)"
            >
              ↶ undo
            </button>
            <span class={["font-mono text-xs tabular-nums", @palette.faint]}>{@words} words</span>
          </div>
        </div>
      </header>

      <div :if={@loaded} class="max-w-2xl mx-auto px-6 pt-28 pb-40">
        <div class="mb-10 flex items-center gap-2 flex-wrap">
          <span
            :for={doc <- @linked}
            class={[
              "group/tag inline-flex items-center gap-1.5 rounded-full ring-1 px-3 py-1 text-xs font-semibold",
              WritingComponents.element_chip(@registry, doc.element_type || doc.kind, @palette.light)
            ]}
          >
            <.link navigate={~p"/write/#{@project.id}/#{doc.id}"} class="hover:underline">
              <span :if={doc.kind == "chapter"} class="opacity-60">¶</span> {doc.title}
            </.link>
            <button
              phx-click="remove_tag"
              phx-value-id={doc.id}
              class="opacity-0 group-hover/tag:opacity-60 hover:!opacity-100"
              title="Untag"
            >
              ✕
            </button>
          </span>

          <div class="relative" phx-click-away={@tag_picker && "close_tag_picker"}>
            <button
              phx-click="toggle_tag_picker"
              class={[
                "rounded-full ring-1 px-3 py-1 font-mono text-xs",
                @palette.rule,
                @palette.faint,
                @palette.hover
              ]}
            >
              + tag
            </button>

            <div
              :if={@tag_picker}
              class={[
                "absolute left-0 top-8 z-30 w-72 rounded-lg border shadow-lg p-1 max-h-80 overflow-y-auto",
                @palette.bg,
                @palette.rule
              ]}
            >
              <button
                :for={doc <- @tag_options}
                phx-click="add_tag"
                phx-value-id={doc.id}
                class={[
                  "flex w-full items-center gap-2 text-left px-3 py-1.5 rounded text-sm",
                  @palette.hover
                ]}
              >
                <span
                  class="inline-block w-2 h-2 rounded-full shrink-0"
                  style={"background: #{WritingComponents.element_hex(@registry, doc.element_type || doc.kind)}"}
                ></span>
                {doc.title}
                <span class={["ml-auto font-mono text-[10px] uppercase", @palette.faint]}>
                  {doc.element_type || doc.kind}
                </span>
              </button>

              <p
                :if={@tag_options == []}
                class={["px-3 py-2 text-xs leading-relaxed", @palette.faint]}
              >
                Nothing to tag yet. Add characters, places and the rest on a <.link
                  navigate={~p"/write/#{@project.id}"}
                  class="underline"
                >plan map</.link>,
                then tag them here.
              </p>
            </div>
          </div>
        </div>

        <section :if={@kind == "planning"} class="mb-10">
          <div
            id={"plan-map-#{@bump}"}
            phx-hook=".PlanMap"
            phx-update="ignore"
            data-canvas={canvas_payload(@raw, @map_docs, @map_edges, @project.theme, @registry)}
            class={[
              "h-[28rem] rounded-xl border overflow-hidden touch-none select-none",
              @palette.rule,
              @palette.card
            ]}
          >
          </div>
          <p class={["mt-2 font-mono text-[10px]", @palette.faint]}>
            drag to arrange · ⌁ connect links two dots · click a dot to open it
          </p>

          <div class="mt-4 flex items-center gap-2 flex-wrap">
            <button
              :for={{id, doc} <- @unplaced}
              phx-click="map_add"
              phx-value-doc={id}
              class={[
                "inline-flex items-center gap-1.5 rounded-full ring-1 px-3 py-1 text-xs font-semibold",
                WritingComponents.element_chip(@registry, doc.element_type, @palette.light),
                @palette.hover
              ]}
            >
              + {doc.title}
            </button>

            <form phx-submit="map_create" class="flex items-center gap-1.5">
              <.type_dropdown
                types={@active_types}
                picked={@tag_type}
                open={@tag_type_menu}
                toggle="toggle_tag_type_menu"
                pick="pick_tag_type"
                palette={@palette}
              />
              <input
                type="text"
                name="name"
                required
                placeholder="New element…"
                autocomplete="off"
                class={[
                  "w-44 rounded border bg-transparent px-2 py-1 text-sm",
                  @palette.rule,
                  "placeholder:opacity-50 focus:outline-none"
                ]}
              />
              <button type="submit" class={["font-mono text-xs px-1", @palette.accent]}>+</button>
            </form>
          </div>

          <div :if={@placed != []} class="mt-3 flex items-center gap-2 flex-wrap">
            <span class={["font-mono text-[10px] uppercase tracking-wider", @palette.faint]}>
              on this map
            </span>
            <span
              :for={{block_id, doc} <- @placed}
              class={[
                "group/dot inline-flex items-center gap-1.5 rounded-full ring-1 px-2.5 py-0.5 text-xs",
                WritingComponents.element_chip(
                  @registry,
                  doc.element_type || doc.kind,
                  @palette.light
                )
              ]}
            >
              {doc.title}
              <button
                phx-click="map_remove"
                phx-value-id={block_id}
                class="opacity-0 group-hover/dot:opacity-60 hover:!opacity-100"
                title="Take off this map (doesn't delete the element)"
              >
                ✕
              </button>
            </span>
          </div>

          <p
            :if={Enum.any?(@raw["blocks"], &(&1["type"] != "node"))}
            class={["mt-10 font-mono text-xs tracking-wider", @palette.muted]}
          >
            NOTES
          </p>
        </section>

        <div
          :for={{block, index} <- Enum.with_index(@raw["blocks"])}
          :if={block["type"] != "node"}
          id={"blk-#{block["id"]}-#{@bump}"}
          data-block-id={block["id"]}
          class="group relative"
        >
          <div phx-click-away={@menu == block["id"] && "close_menu"}>
            <button
              phx-click="toggle_menu"
              phx-value-id={block["id"]}
              class={[
                "absolute -left-10 top-1.5 w-7 h-7 rounded-md font-mono text-sm",
                "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition",
                @palette.faint,
                @palette.hover
              ]}
              title="Block options"
            >
              ⋯
            </button>

            <div
              :if={@menu == block["id"]}
              class={[
                "absolute -left-10 top-10 z-30 w-44 rounded-lg border shadow-lg p-1",
                @palette.bg,
                @palette.rule
              ]}
            >
              <button
                :for={type <- palette(@kind, @element_type) -- ~w(portrait)}
                :if={type != block["type"]}
                phx-click="set_type"
                phx-value-id={block["id"]}
                phx-value-type={type}
                class={["block w-full text-left px-3 py-1.5 rounded text-sm", @palette.hover]}
              >
                {type_label(type)}
              </button>
              <button
                phx-click="delete_block"
                phx-value-id={block["id"]}
                class={[
                  "block w-full text-left px-3 py-1.5 rounded text-sm text-red-600",
                  @palette.hover
                ]}
              >
                ✕ delete block
              </button>
            </div>
          </div>

          <.block_editor
            block={block}
            index={index}
            bump={@bump}
            kind={@kind}
            palette={@palette}
            project={@project}
            portrait_target={@portrait_target}
            uploads={@uploads}
          />
        </div>

        <div class={["mt-12 pt-6 border-t flex gap-2 flex-wrap", @palette.rule]}>
          <button
            :for={type <- palette(@kind, @element_type)}
            phx-click="add_block"
            phx-value-type={type}
            class={[
              "px-3 py-1.5 rounded-lg border font-mono text-xs",
              @palette.rule,
              @palette.muted,
              @palette.hover
            ]}
          >
            + {type_label(type)}
          </button>
        </div>
      </div>

      <div
        :if={@edit_error}
        phx-click="dismiss_error"
        class="fixed bottom-6 inset-x-0 z-50 flex justify-center px-6 cursor-pointer"
      >
        <p class="rounded-lg bg-red-900 text-red-50 text-sm px-4 py-2 shadow-lg">
          {@edit_error} <span class="opacity-60 font-mono text-xs ml-2">dismiss</span>
        </p>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".WritingBlock">
        export default {
          mounted() {
            this.dirty = false
            this.resize()
            this.el.addEventListener("input", () => {
              this.dirty = true
              this.resize()
              clearTimeout(this.timer)
              this.timer = setTimeout(() => this.flush(), 1200)
            })
            this.el.addEventListener("blur", () => this.flush())
            // Enter is a plain newline (native) — a block holds many
            // paragraphs, so drafting never touches the server per Return.
            // Escape just commits and drops focus.
            this.el.addEventListener("keydown", (e) => {
              if (e.key === "Escape") this.el.blur()
            })
          },
          updated() { this.resize() },
          destroyed() { clearTimeout(this.timer) },
          resize() {
            if (this.el.tagName !== "TEXTAREA") return
            this.el.style.height = "auto"
            this.el.style.height = this.el.scrollHeight + "px"
          },
          flush() {
            clearTimeout(this.timer)
            if (!this.dirty) return
            this.dirty = false
            this.pushEvent("save_block", {
              id: this.el.dataset.blockId,
              field: this.el.dataset.field,
              value: this.el.value,
            })
          },
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".PlanMap">
        export default {
          mounted() {
            const {nodes, edges, ink, edgeColor} = JSON.parse(this.el.dataset.canvas)
            const NS = "http://www.w3.org/2000/svg"
            const byDoc = new Map(nodes.map((n) => [n.doc, n]))

            const svg = document.createElementNS(NS, "svg")
            svg.setAttribute("width", "100%")
            svg.setAttribute("height", "100%")
            // Fit the stored layout, never smaller than the default page.
            const pad = 60
            const xs = nodes.map((n) => n.x), ys = nodes.map((n) => n.y)
            const minX = Math.min(0, ...xs.map((x) => x - pad))
            const minY = Math.min(0, ...ys.map((y) => y - pad))
            const maxX = Math.max(1000, ...xs.map((x) => x + pad))
            const maxY = Math.max(560, ...ys.map((y) => y + pad))
            svg.setAttribute("viewBox", `${minX} ${minY} ${maxX - minX} ${maxY - minY}`)
            this.el.style.position = "relative"
            this.el.appendChild(svg)

            edges.forEach((e) => {
              const a = byDoc.get(e.a), b = byDoc.get(e.b)
              if (!a || !b) return
              const line = document.createElementNS(NS, "line")
              line.setAttribute("stroke", edgeColor)
              line.setAttribute("stroke-width", "1.5")
              const draw = () => {
                line.setAttribute("x1", a.x); line.setAttribute("y1", a.y)
                line.setAttribute("x2", b.x); line.setAttribute("y2", b.y)
              }
              draw()
              a.redraws = (a.redraws || []).concat(draw)
              b.redraws = (b.redraws || []).concat(draw)
              svg.appendChild(line)
            })

            // Connect mode: a small toggle the hook owns (the canvas is
            // phx-update=ignore, so LiveView can't render into it).
            let connectFrom = null
            const toggle = document.createElement("button")
            toggle.textContent = "⌁ connect"
            toggle.style.cssText =
              "position:absolute;top:8px;right:8px;font:10px ui-monospace,monospace;" +
              `padding:4px 8px;border-radius:6px;border:1px solid ${edgeColor};color:${ink};opacity:.7`
            toggle.addEventListener("click", () => {
              this.connectMode = !this.connectMode
              connectFrom = null
              nodes.forEach((n) => n.ring.setAttribute("stroke-opacity", "0"))
              toggle.style.opacity = this.connectMode ? "1" : ".7"
              toggle.style.fontWeight = this.connectMode ? "bold" : "normal"
            })
            this.el.appendChild(toggle)

            const svgPoint = (e) => {
              const pt = svg.createSVGPoint()
              pt.x = e.clientX
              pt.y = e.clientY
              return pt.matrixTransform(svg.getScreenCTM().inverse())
            }

            nodes.forEach((n) => {
              const g = document.createElementNS(NS, "g")
              g.style.cursor = "pointer"
              const ring = document.createElementNS(NS, "circle")
              ring.setAttribute("r", 15)
              ring.setAttribute("fill", "none")
              ring.setAttribute("stroke", n.color)
              ring.setAttribute("stroke-width", "2")
              ring.setAttribute("stroke-opacity", "0")
              const circle = document.createElementNS(NS, "circle")
              circle.setAttribute("r", 10)
              circle.setAttribute("fill", n.color)
              circle.setAttribute("fill-opacity", "0.85")
              const label = document.createElementNS(NS, "text")
              label.textContent = n.title
              label.setAttribute("fill", ink)
              label.setAttribute("font-size", "12")
              label.setAttribute("text-anchor", "middle")
              g.appendChild(ring)
              g.appendChild(circle)
              g.appendChild(label)
              svg.appendChild(g)
              n.ring = ring

              const draw = () => {
                ring.setAttribute("cx", n.x); ring.setAttribute("cy", n.y)
                circle.setAttribute("cx", n.x); circle.setAttribute("cy", n.y)
                label.setAttribute("x", n.x); label.setAttribute("y", n.y + 26)
                ;(n.redraws || []).forEach((fn) => fn())
              }
              draw()

              g.addEventListener("pointerdown", (e) => {
                e.preventDefault()
                g.setPointerCapture(e.pointerId)
                let moved = false
                const onMove = (ev) => {
                  if (this.connectMode) return
                  moved = true
                  const p = svgPoint(ev)
                  n.x = Math.max(0, p.x)
                  n.y = Math.max(0, p.y)
                  draw()
                }
                const onUp = () => {
                  g.removeEventListener("pointermove", onMove)
                  g.removeEventListener("pointerup", onUp)
                  if (moved) {
                    this.pushEvent("map_move", {id: n.block, x: n.x, y: n.y})
                  } else if (this.connectMode) {
                    if (!connectFrom) {
                      connectFrom = n
                      ring.setAttribute("stroke-opacity", "1")
                    } else if (connectFrom !== n) {
                      this.pushEvent("map_connect", {a: connectFrom.block, b: n.block})
                    }
                  } else {
                    this.pushEvent("map_open", {doc: n.doc})
                  }
                }
                g.addEventListener("pointermove", onMove)
                g.addEventListener("pointerup", onUp)
              })
            })
          },
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".WritingDocNav">
        export default {
          mounted() {
            this.handleEvent("focus_block", ({id, pos}) => {
              requestAnimationFrame(() => {
                const holder = document.querySelector(`[data-block-id="${id}"]`)
                if (!holder) return
                const el = holder.querySelector("textarea, input")
                if (!el) return
                el.focus()
                if (el.setSelectionRange) el.setSelectionRange(pos, pos)
              })
            })

            // Cmd/Ctrl+Z = event-log undo. While the caret is IN a block
            // (a text field), the browser's native undo of the just-typed
            // text should win — those keystrokes haven't been committed as
            // ops yet — so only intercept when focus is on the page chrome.
            this.onKey = (e) => {
              if (e.key !== "z" || !(e.metaKey || e.ctrlKey) || e.shiftKey) return
              const t = document.activeElement
              if (t && (t.tagName === "TEXTAREA" || t.tagName === "INPUT")) return
              e.preventDefault()
              this.pushEvent("undo")
            }
            window.addEventListener("keydown", this.onKey)
          },
          destroyed() {
            window.removeEventListener("keydown", this.onKey)
          },
        }
      </script>
    </main>
    """
  end

  # One editor per block type. Textareas/inputs carry the .WritingBlock hook
  # (debounced saves, split/merge keys); ids embed @bump so structural
  # changes remount them with committed truth.
  attr :block, :map, required: true
  attr :index, :integer, required: true
  attr :bump, :integer, required: true
  attr :kind, :string, required: true
  attr :palette, :map, required: true
  attr :project, :any, default: nil
  attr :portrait_target, :string, default: nil
  attr :uploads, :any, default: nil

  defp block_editor(%{block: %{"type" => "scene_break"}} = assigns) do
    ~H"""
    <div class={["text-center py-6 tracking-[1em] select-none", @palette.faint]}>✳ ✳ ✳</div>
    """
  end

  # A labeled profile field — Background, Physicality, Traits, or whatever
  # the writer names it.
  defp block_editor(%{block: %{"type" => "field"}} = assigns) do
    ~H"""
    <div class={["mt-8 border-l-2 pl-4", @palette.rule]}>
      <input
        id={"label-#{@block["id"]}-#{@bump}"}
        phx-hook=".WritingBlock"
        phx-update="ignore"
        data-block-id={@block["id"]}
        data-field="label"
        type="text"
        value={@block["label"]}
        placeholder="FIELD"
        autocomplete="off"
        class={[
          "w-full bg-transparent border-0 p-0 font-mono text-xs tracking-widest uppercase focus:outline-none focus:ring-0 placeholder:opacity-40",
          @palette.accent
        ]}
      />
      <textarea
        id={"ta-#{@block["id"]}-#{@bump}"}
        phx-hook=".WritingBlock"
        phx-update="ignore"
        data-block-id={@block["id"]}
        data-field="text"
        rows="1"
        placeholder="…"
        spellcheck="true"
        class="w-full resize-none overflow-hidden bg-transparent border-0 p-0 mt-1.5 leading-relaxed focus:outline-none focus:ring-0 placeholder:opacity-40"
      >{@block["text"]}</textarea>
    </div>
    """
  end

  # The portrait slot: an encrypted upload, or the dashed invitation to add
  # one. Replacing mints a new image id (undo restores the old one).
  defp block_editor(%{block: %{"type" => "portrait"}} = assigns) do
    ~H"""
    <div class="my-6 flex flex-col items-center gap-3">
      <div :if={@block["image"] not in [nil, ""]} class="relative group/img">
        <img
          src={~p"/write/#{@project.id}/image/#{@block["image"]}"}
          alt={@block["caption"] || "portrait"}
          class="rounded-xl max-h-80 max-w-full shadow-md"
        />
        <div class="absolute bottom-2 right-2 flex gap-2 opacity-0 group-hover/img:opacity-100 transition">
          <button
            phx-click="start_portrait"
            phx-value-id={@block["id"]}
            class="rounded bg-black/60 text-white font-mono text-[10px] px-2 py-1"
          >
            replace
          </button>
          <button
            phx-click="remove_portrait"
            phx-value-id={@block["id"]}
            class="rounded bg-black/60 text-red-300 font-mono text-[10px] px-2 py-1"
          >
            remove
          </button>
        </div>
      </div>

      <button
        :if={@block["image"] in [nil, ""] and @portrait_target != @block["id"]}
        phx-click="start_portrait"
        phx-value-id={@block["id"]}
        class={[
          "w-44 h-52 rounded-xl border-2 border-dashed flex flex-col items-center justify-center gap-2 font-mono text-xs",
          @palette.rule,
          @palette.faint,
          @palette.hover
        ]}
      >
        <span class="text-2xl">◉</span> add portrait
      </button>

      <form
        :if={@portrait_target == @block["id"]}
        phx-change="validate_portrait"
        phx-submit="save_portrait"
        class={["flex items-center gap-2 rounded-lg border p-2", @palette.rule, @palette.card]}
      >
        <input type="hidden" name="block" value={@block["id"]} />
        <.live_file_input upload={@uploads.portrait} class="text-xs max-w-52" />
        <span
          :for={entry <- @uploads.portrait.entries}
          class={["font-mono text-[10px]", @palette.muted]}
        >
          {entry.progress}%
          <span :for={err <- upload_errors(@uploads.portrait, entry)} class="text-red-600">
            {upload_error_label(err)}
          </span>
        </span>
        <button type="submit" class={["font-mono text-xs", @palette.accent]}>save</button>
        <button
          type="button"
          phx-click="cancel_portrait"
          class={["font-mono text-xs", @palette.faint]}
        >
          ✕
        </button>
      </form>

      <input
        :if={@block["image"] not in [nil, ""]}
        id={"caption-#{@block["id"]}-#{@bump}"}
        phx-hook=".WritingBlock"
        phx-update="ignore"
        data-block-id={@block["id"]}
        data-field="caption"
        type="text"
        value={@block["caption"]}
        placeholder="a caption…"
        autocomplete="off"
        class={[
          "bg-transparent border-0 p-0 text-sm text-center italic focus:outline-none focus:ring-0 placeholder:opacity-40",
          @palette.muted
        ]}
      />
    </div>
    """
  end

  defp block_editor(%{block: %{"type" => "heading"}} = assigns) do
    ~H"""
    <textarea
      id={"ta-#{@block["id"]}-#{@bump}"}
      phx-hook=".WritingBlock"
      phx-update="ignore"
      data-block-id={@block["id"]}
      data-field="text"
      rows="1"
      placeholder="Heading…"
      spellcheck="true"
      class="w-full resize-none overflow-hidden bg-transparent border-0 p-0 mt-10 mb-2 text-3xl font-bold leading-tight focus:outline-none focus:ring-0 placeholder:opacity-40"
    >{@block["text"]}</textarea>
    """
  end

  defp block_editor(%{block: %{"type" => "epigraph"}} = assigns) do
    ~H"""
    <div class="my-8 px-8">
      <textarea
        id={"ta-#{@block["id"]}-#{@bump}"}
        phx-hook=".WritingBlock"
        phx-update="ignore"
        data-block-id={@block["id"]}
        data-field="text"
        rows="1"
        placeholder="An epigraph…"
        spellcheck="true"
        class="w-full resize-none overflow-hidden bg-transparent border-0 p-0 text-lg italic text-center leading-relaxed focus:outline-none focus:ring-0 placeholder:opacity-40"
      >{@block["text"]}</textarea>
      <input
        id={"src-#{@block["id"]}-#{@bump}"}
        phx-hook=".WritingBlock"
        phx-update="ignore"
        data-block-id={@block["id"]}
        data-field="source"
        type="text"
        value={@block["source"]}
        placeholder="— attribution"
        autocomplete="off"
        class={[
          "w-full bg-transparent border-0 p-0 mt-1 text-sm text-right focus:outline-none focus:ring-0 placeholder:opacity-40",
          @palette.muted
        ]}
      />
    </div>
    """
  end

  defp block_editor(%{block: %{"type" => "character"}} = assigns) do
    ~H"""
    <div class={["my-4 rounded-xl border p-5", @palette.rule, @palette.card]}>
      <p class={["font-mono text-[10px] tracking-widest uppercase mb-2", @palette.faint]}>
        character
      </p>
      <input
        id={"name-#{@block["id"]}-#{@bump}"}
        phx-hook=".WritingBlock"
        phx-update="ignore"
        data-block-id={@block["id"]}
        data-field="name"
        type="text"
        value={@block["name"]}
        placeholder="Name"
        autocomplete="off"
        class="w-full bg-transparent border-0 p-0 text-xl font-bold focus:outline-none focus:ring-0 placeholder:opacity-40"
      />
      <textarea
        id={"ta-#{@block["id"]}-#{@bump}"}
        phx-hook=".WritingBlock"
        phx-update="ignore"
        data-block-id={@block["id"]}
        data-field="text"
        rows="1"
        placeholder="Who they are, what they want, what they hide…"
        spellcheck="true"
        class="w-full resize-none overflow-hidden bg-transparent border-0 p-0 mt-2 leading-relaxed focus:outline-none focus:ring-0 placeholder:opacity-40"
      >{@block["text"]}</textarea>
    </div>
    """
  end

  defp block_editor(%{block: %{"type" => "beat"}} = assigns) do
    ~H"""
    <div class={["my-4 rounded-xl border p-5", @palette.rule, @palette.card]}>
      <input
        id={"label-#{@block["id"]}-#{@bump}"}
        phx-hook=".WritingBlock"
        phx-update="ignore"
        data-block-id={@block["id"]}
        data-field="label"
        type="text"
        value={@block["label"]}
        placeholder="BEAT"
        autocomplete="off"
        class={[
          "w-full bg-transparent border-0 p-0 font-mono text-xs tracking-widest uppercase focus:outline-none focus:ring-0 placeholder:opacity-40",
          @palette.accent
        ]}
      />
      <textarea
        id={"ta-#{@block["id"]}-#{@bump}"}
        phx-hook=".WritingBlock"
        phx-update="ignore"
        data-block-id={@block["id"]}
        data-field="text"
        rows="1"
        placeholder="What happens, and why it matters…"
        spellcheck="true"
        class="w-full resize-none overflow-hidden bg-transparent border-0 p-0 mt-2 leading-relaxed focus:outline-none focus:ring-0 placeholder:opacity-40"
      >{@block["text"]}</textarea>
    </div>
    """
  end

  defp block_editor(assigns) do
    ~H"""
    <textarea
      id={"ta-#{@block["id"]}-#{@bump}"}
      phx-hook=".WritingBlock"
      phx-update="ignore"
      data-block-id={@block["id"]}
      data-field="text"
      rows="1"
      placeholder={if @index == 0, do: "Begin…", else: ""}
      spellcheck="true"
      class="w-full resize-none overflow-hidden bg-transparent border-0 p-0 my-2 text-lg leading-8 focus:outline-none focus:ring-0 placeholder:opacity-40"
    >{@block["text"]}</textarea>
    """
  end
end
