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
           nav: %{prev: nil, next: nil},
           active_block: nil,
           special_open: false,
           link_panel: nil,
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
             map: map_data(project, doc_id, doc.kind),
             nav: chapter_nav(project_id, doc_id, doc.kind)
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
       map_edges: data.map.edges,
       nav: data.nav
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

  # The block hook reports which block the caret is in, so a new block lands
  # right after the one you're working on — not way down at the end.
  def handle_event("block_focused", %{"id" => id}, socket) do
    {:noreply, assign(socket, active_block: id)}
  end

  # ----- Structure (block menu / add bar) ------------------------------------------

  def handle_event("add_block", %{"type" => type}, socket) do
    if type in palette(socket.assigns.kind, socket.assigns.element_type) do
      after_pos = insert_after(socket)

      {:noreply,
       commit(socket, [%InsertBlock{block: default_block(type), after: after_pos}],
         bump: true,
         focus: &{inserted_id(&1, after_pos), 0}
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

  def handle_event("toggle_special", _params, socket) do
    {:noreply, assign(socket, special_open: not socket.assigns.special_open)}
  end

  def handle_event("close_special", _params, socket) do
    {:noreply, assign(socket, special_open: false)}
  end

  # The link panel: opened from the format bar, ⌘K, or the selection popover
  # (the client stashes which selection to wrap). Picking a target round-trips
  # as "apply_link" and the client inserts the [[target|display]] wikilink.
  def handle_event("open_link_panel", %{"text" => text}, socket) do
    {:noreply, assign(socket, link_panel: link_panel_state(socket, String.trim(text)))}
  end

  def handle_event("link_search", %{"q" => q}, socket) do
    {:noreply, assign(socket, link_panel: link_panel_state(socket, q))}
  end

  def handle_event("link_submit", _params, socket) do
    case socket.assigns.link_panel do
      %{results: [first | _]} ->
        {:noreply,
         socket |> assign(link_panel: nil) |> push_event("apply_link", %{target: first.label})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("pick_link", %{"target" => target}, socket) do
    {:noreply, socket |> assign(link_panel: nil) |> push_event("apply_link", %{target: target})}
  end

  # Create a tag (element) named by the query and link to it in one step, so a
  # name that doesn't exist yet still yields a live link, not a dead one.
  def handle_event("create_and_link", %{"type" => type, "name" => name}, socket) do
    name = String.trim(name)

    with true <- type in Enum.map(socket.assigns.active_types, & &1.key),
         {:ok, _id} <- ProjectServer.create_element(socket.assigns.project.id, type, name) do
      {:noreply, socket |> assign(link_panel: nil) |> push_event("apply_link", %{target: name})}
    else
      _ -> {:noreply, assign(socket, link_panel: link_panel_state(socket, name))}
    end
  end

  def handle_event("close_link_panel", _params, socket) do
    {:noreply, assign(socket, link_panel: nil)}
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

  # ----- Undo / redo (the event log, not a socket stack) -------------------------------

  def handle_event("undo", _params, socket), do: {:noreply, step(socket, :undo)}
  def handle_event("redo", _params, socket), do: {:noreply, step(socket, :redo)}

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

  # Undo/redo share a path: both append an inverting event and refresh, or
  # no-op when there's nothing to step to.
  defp step(socket, dir) do
    %{project: project, doc_id: doc_id, seq: seq} = socket.assigns
    actor = socket.assigns.current_user.id

    result =
      case dir do
        :undo -> ProjectServer.undo(project.id, doc_id, seq, actor)
        :redo -> ProjectServer.redo(project.id, doc_id, seq, actor)
      end

    case result do
      {:ok, raw, seq} ->
        socket |> broadcast_update() |> refresh(raw, seq)

      {:error, reason} when reason in [:nothing_to_undo, :nothing_to_redo] ->
        socket

      {:error, :stale} ->
        reload_stale(socket)

      {:error, [error | _]} ->
        assign(socket, edit_error: "Can't #{dir} that: #{error}")
    end
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

  # State for the link panel. Targets are the project's real pages — chapters
  # and tags (elements) — so every link resolves in read view; there are no
  # dead links. When the query names nothing yet, `can_create` lets the panel
  # offer "create it as a tag" inline. This is the single place that decides
  # what text can link TO; to grow linking (contacts, sharing) add target
  # kinds here and teach resolve_wikilinks (writing_components.ex) their shape.
  defp link_panel_state(socket, query) do
    results = link_targets(socket, query)
    trimmed = String.trim(query)

    can_create =
      trimmed != "" and
        not Enum.any?(results, &(String.downcase(&1.label) == String.downcase(trimmed)))

    %{query: query, results: results, can_create: can_create}
  end

  defp link_targets(socket, query) do
    q = query |> String.trim() |> String.downcase()

    socket.assigns.project.id
    |> ProjectServer.list_docs()
    |> Enum.filter(fn doc ->
      doc.id != socket.assigns.doc_id and doc.kind in ~w(chapter element) and
        (q == "" or String.contains?(String.downcase(doc.title), q))
    end)
    |> Enum.take(8)
    |> Enum.map(&%{label: &1.title, kind: link_kind_label(socket, &1)})
  end

  # A target's human kind label: "chapter", or the tag's element-type label.
  defp link_kind_label(_socket, %{kind: "chapter"}), do: "chapter"

  defp link_kind_label(socket, %{element_type: type}) do
    case socket.assigns.registry[type] do
      %{label: label} -> label
      _ -> type
    end
  end

  defp find_block(raw, id), do: Enum.find(raw["blocks"], &(&1["id"] == id))

  # Where a newly added block goes: right after the block the caret was last
  # in, or at the end if there's no live focus to anchor to.
  defp insert_after(socket) do
    if socket.assigns.active_block && find_block(socket.assigns.raw, socket.assigns.active_block),
      do: socket.assigns.active_block,
      else: "end"
  end

  # The id of the block that `add_block` just inserted, for caret placement:
  # the one sitting after the anchor (or the last block when appended).
  defp inserted_id(raw, "end"), do: List.last(raw["blocks"])["id"]

  defp inserted_id(raw, anchor_id) do
    blocks = raw["blocks"]

    case Enum.find_index(blocks, &(&1["id"] == anchor_id)) do
      nil -> List.last(blocks)["id"]
      index -> Enum.at(blocks, index + 1)["id"]
    end
  end

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

  # Prev/next chapter (by book order) for the editor's chapter-to-chapter nav.
  # Only chapters get it — plan maps and elements aren't a reading sequence.
  defp chapter_nav(project_id, doc_id, "chapter") do
    chapters =
      project_id
      |> ProjectServer.list_docs()
      |> Enum.filter(&(&1.kind == "chapter"))
      |> Enum.sort_by(& &1.position)

    index = Enum.find_index(chapters, &(&1.id == doc_id))
    at = fn i -> if index, do: Enum.at(chapters, i) end

    %{prev: index && index > 0 && at.(index - 1), next: index && at.(index + 1)}
    |> Map.new(fn {k, v} -> {k, if(is_map(v), do: %{id: v.id, title: v.title}, else: nil)} end)
  end

  defp chapter_nav(_project_id, _doc_id, _kind), do: %{prev: nil, next: nil}

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
            <.link
              :if={@kind != "planning"}
              navigate={~p"/write/#{@project.id}/#{@doc_id}/read"}
              class={["font-mono text-xs", @palette.muted, "hover:opacity-70"]}
              title="Read view (rendered)"
            >
              read
            </.link>
            <button
              phx-click="undo"
              class={["font-mono text-xs", @palette.muted, "hover:opacity-70"]}
              title="Undo — ⌘Z (event-logged, survives refresh)"
            >
              ↶ undo
            </button>
            <button
              phx-click="redo"
              class={["font-mono text-xs", @palette.muted, "hover:opacity-70"]}
              title="Redo — ⌘⇧Z"
            >
              ↷ redo
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

        <div class={["mt-4 flex flex-wrap items-center gap-1", @palette.muted]}>
          <button
            type="button"
            data-wrap="**"
            title="Bold — ⌘B"
            class={["px-2 h-7 rounded font-bold", @palette.hover]}
          >
            B
          </button>
          <button
            type="button"
            data-wrap="*"
            title="Italic — ⌘I"
            class={["px-2 h-7 rounded italic", @palette.hover]}
          >
            I
          </button>
          <button
            type="button"
            data-wrap="~~"
            title="Strikethrough — ⌘⇧X"
            class={["px-2 h-7 rounded line-through", @palette.hover]}
          >
            S
          </button>
          <button
            type="button"
            data-prefix="- "
            title="Bulleted list"
            class={["px-2 h-7 rounded", @palette.hover]}
          >
            • list
          </button>
          <button
            type="button"
            data-prefix="## "
            title="Heading"
            class={["px-2 h-7 rounded font-bold", @palette.hover]}
          >
            H
          </button>
          <button
            type="button"
            data-link
            title="Link to a page — ⌘K"
            class={["px-2 h-7 rounded inline-flex items-center", @palette.hover]}
          >
            <.icon name="hero-link" class="size-4" />
          </button>
          <span class={["ml-auto font-mono text-[10px] uppercase tracking-wider", @palette.faint]}>
            ⌘Z undo · ⌘⇧Z redo
          </span>
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

        <div
          id="special-chars"
          phx-hook=".SpecialChars"
          class="mt-3 relative"
          phx-click-away={@special_open && "close_special"}
        >
          <button
            phx-click="toggle_special"
            class={[
              "inline-flex items-center gap-2 px-3 py-1.5 rounded-lg border font-mono text-xs",
              @palette.rule,
              @palette.muted,
              @palette.hover
            ]}
          >
            Ω symbols
          </button>

          <div
            :if={@special_open}
            class={[
              "fixed bottom-6 left-6 z-40 w-72 max-w-[calc(100vw-3rem)] max-h-[60vh] overflow-auto rounded-lg border shadow-lg p-3 text-left",
              @palette.bg,
              @palette.rule
            ]}
          >
            <p class={["font-mono text-[10px] uppercase tracking-wider mb-2", @palette.faint]}>
              insert at the caret
            </p>
            <div class="flex flex-wrap gap-1">
              <button
                :for={
                  ch <-
                    ~w(à á â ä ã è é ê ë ì í î ï ò ó ô ö õ ù ú û ü ñ ç æ œ ø å – — “ ” ‘ ’ … ×)
                }
                type="button"
                data-char={ch}
                class={["w-7 h-7 rounded text-base", @palette.hover]}
              >
                {ch}
              </button>
            </div>
          </div>
        </div>

        <button
          id="selection-link"
          type="button"
          data-link
          phx-update="ignore"
          hidden
          class={[
            "fixed z-40 inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg border shadow-lg font-mono text-xs",
            @palette.bg,
            @palette.rule,
            @palette.hover
          ]}
        >
          <.icon name="hero-link" class="size-3.5" /> link
        </button>

        <div :if={@link_panel} class="fixed bottom-6 inset-x-0 z-50 flex justify-center px-6">
          <div
            class={["w-96 max-w-full rounded-lg border shadow-lg p-3", @palette.bg, @palette.rule]}
            phx-click-away="close_link_panel"
            phx-window-keydown="close_link_panel"
            phx-key="escape"
          >
            <p class={["font-mono text-[10px] uppercase tracking-wider mb-2", @palette.faint]}>
              link to a chapter or tag
            </p>
            <form phx-change="link_search" phx-submit="link_submit">
              <input
                type="text"
                name="q"
                value={@link_panel.query}
                placeholder="Search chapters and tags…"
                autocomplete="off"
                phx-mounted={JS.focus()}
                class={[
                  "w-full rounded-lg px-3 py-2 bg-transparent border text-sm",
                  @palette.rule,
                  "placeholder:opacity-50 focus:outline-none"
                ]}
              />
            </form>
            <div :if={@link_panel.results != []} class="mt-2 flex flex-col">
              <button
                :for={target <- @link_panel.results}
                phx-click="pick_link"
                phx-value-target={target.label}
                class={[
                  "flex items-center justify-between gap-3 rounded px-2 py-1.5 text-left text-sm",
                  @palette.hover
                ]}
              >
                <span class="truncate">{target.label}</span>
                <span class={["font-mono text-[10px] uppercase shrink-0", @palette.faint]}>
                  {target.kind}
                </span>
              </button>
            </div>

            <div :if={@link_panel.can_create} class={["mt-3 pt-3 border-t", @palette.rule]}>
              <p class={["text-xs mb-2", @palette.muted]}>
                No page called “{@link_panel.query}”. Create it as a tag:
              </p>
              <div class="flex flex-wrap gap-1.5">
                <button
                  :for={type <- @active_types}
                  phx-click="create_and_link"
                  phx-value-type={type.key}
                  phx-value-name={@link_panel.query}
                  class={[
                    "inline-flex items-center gap-1.5 rounded-full ring-1 px-3 py-1 text-xs font-semibold transition",
                    WritingComponents.chip_class(type.color, @palette.light),
                    "opacity-70 hover:opacity-100"
                  ]}
                >
                  + {type.label}
                </button>
              </div>
            </div>

            <p
              :if={@link_panel.results == [] and not @link_panel.can_create}
              class={["text-xs mt-2", @palette.muted]}
            >
              Type a name to find a chapter or tag, or create a new tag.
            </p>
            <p class={["text-xs mt-3", @palette.faint]}>
              Links open the page in read view.
            </p>
          </div>
        </div>

        <nav
          :if={@nav.prev || @nav.next}
          class={["mt-16 pt-6 border-t flex items-center justify-between gap-4", @palette.rule]}
        >
          <.link
            :if={@nav.prev}
            navigate={~p"/write/#{@project.id}/#{@nav.prev.id}"}
            class={["group flex flex-col", @palette.hover, "rounded-lg px-3 py-2 -mx-3"]}
          >
            <span class={["font-mono text-[10px] uppercase tracking-wider", @palette.faint]}>
              ← previous
            </span>
            <span class="font-semibold">{@nav.prev.title}</span>
          </.link>
          <span :if={is_nil(@nav.prev)}></span>

          <.link
            :if={@nav.next}
            navigate={~p"/write/#{@project.id}/#{@nav.next.id}"}
            class={[
              "group flex flex-col items-end text-right",
              @palette.hover,
              "rounded-lg px-3 py-2 -mx-3"
            ]}
          >
            <span class={["font-mono text-[10px] uppercase tracking-wider", @palette.faint]}>
              next chapter →
            </span>
            <span class="font-semibold">{@nav.next.title}</span>
          </.link>
        </nav>
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
            // Report the caret's block so a new block is added right after it.
            this.el.addEventListener("focus", () =>
              this.pushEvent("block_focused", {id: this.el.dataset.blockId})
            )
            // Enter is a plain newline (native) — a block holds many
            // paragraphs, so drafting never touches the server per Return —
            // except inside a list, where it continues the marker (and Enter
            // on an empty item clears it, exiting the list).
            // Escape just commits and drops focus.
            this.el.addEventListener("keydown", (e) => {
              if (e.key === "Escape") this.el.blur()
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing &&
                  this.el.tagName === "TEXTAREA") this.continueList(e)
            })
          },
          continueList(e) {
            const t = this.el
            if (t.selectionStart !== t.selectionEnd) return
            const s = t.selectionStart
            const lineStart = t.value.lastIndexOf("\n", s - 1) + 1
            const line = t.value.slice(lineStart, s)
            const m = line.match(/^(\s*)([-*+]|\d+[.)])\s+/)
            if (!m) return
            e.preventDefault()
            if (line.length === m[0].length) {
              // Empty item: Enter exits the list instead of adding another.
              t.setRangeText("", lineStart, s, "end")
            } else {
              const marker = /^\d/.test(m[2])
                ? (parseInt(m[2], 10) + 1) + m[2].slice(-1)
                : m[2]
              t.setRangeText("\n" + m[1] + marker + " ", s, s, "end")
            }
            t.dispatchEvent(new Event("input", {bubbles: true}))
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
            this.el.style.position = "relative"
            this.el.appendChild(svg)

            // Zoom: the viewBox is fit to the node cloud (never smaller than
            // the default page), then scaled by this.zoom around the content
            // centre. The wheel and the +/−/⤢ buttons drive it; dragging reads
            // getScreenCTM so node moves stay correct at any zoom.
            const pad = 60
            this.zoom = 1
            const clampZoom = (z) => Math.min(4, Math.max(0.3, z))
            const fitView = () => {
              const xs = nodes.map((n) => n.x), ys = nodes.map((n) => n.y)
              const minX = Math.min(0, ...xs.map((x) => x - pad))
              const minY = Math.min(0, ...ys.map((y) => y - pad))
              const maxX = Math.max(1000, ...xs.map((x) => x + pad))
              const maxY = Math.max(560, ...ys.map((y) => y + pad))
              const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
              const w = (maxX - minX) / this.zoom, h = (maxY - minY) / this.zoom
              svg.setAttribute("viewBox", `${cx - w / 2} ${cy - h / 2} ${w} ${h}`)
            }
            fitView()

            this.el.addEventListener(
              "wheel",
              (e) => {
                e.preventDefault()
                this.zoom = clampZoom(this.zoom * (e.deltaY < 0 ? 1.1 : 0.9))
                fitView()
              },
              {passive: false}
            )

            const controls = document.createElement("div")
            controls.style.cssText =
              "position:absolute;bottom:12px;right:12px;display:flex;gap:6px;z-index:1"
            ;[["−", () => (this.zoom = clampZoom(this.zoom * 0.8))],
              ["⤢", () => (this.zoom = 1)],
              ["+", () => (this.zoom = clampZoom(this.zoom * 1.25))]].forEach(([txt, fn]) => {
              const b = document.createElement("button")
              b.type = "button"
              b.textContent = txt
              b.style.cssText =
                `width:28px;height:28px;border-radius:6px;font:14px ui-monospace,monospace;` +
                `border:1px solid ${edgeColor};color:${ink};background:transparent;cursor:pointer`
              b.addEventListener("click", () => { fn(); fitView() })
              controls.appendChild(b)
            })
            this.el.appendChild(controls)

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

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SpecialChars">
        const CONTROLS = "[data-char],[data-wrap],[data-prefix],[data-link]"

        export default {
          mounted() {
            // Remember the writing field the caret was last in — clicking a
            // format/symbol control steals focus, so we insert back into
            // this remembered target at its preserved caret. Controls live
            // both in the format bar and the Ω popup, so listen on document.
            this.target = null
            this.onFocusin = (e) => {
              const el = e.target
              if (el && el.dataset && el.dataset.blockId &&
                  (el.tagName === "TEXTAREA" || el.tagName === "INPUT")) {
                this.target = el
              }
            }
            document.addEventListener("focusin", this.onFocusin)

            this.onMousedown = (e) => {
              // Keep the textarea's focus/selection while clicking a control.
              if (e.target.closest && e.target.closest(CONTROLS)) e.preventDefault()
            }
            document.addEventListener("mousedown", this.onMousedown)

            this.onClick = (e) => {
              const btn = e.target.closest && e.target.closest(CONTROLS)
              if (!btn) return
              if (btn.dataset.link !== undefined) this.openLinkPanel()
              else this.apply(btn.dataset)
            }
            document.addEventListener("click", this.onClick)

            // Formatting shortcuts while typing: ⌘B, ⌘I, ⌘⇧X, ⌘K link.
            this.onKey = (e) => {
              if (!(e.metaKey || e.ctrlKey) || e.altKey) return
              const a = document.activeElement
              // Don't hijack shortcuts aimed at some other input on the page.
              if (a && (a.tagName === "TEXTAREA" || a.tagName === "INPUT") &&
                  !(a.dataset && a.dataset.blockId)) return
              const k = e.key.toLowerCase()
              if (k === "k" && !e.shiftKey) {
                e.preventDefault()
                return this.openLinkPanel()
              }
              let d = null
              if (k === "b" && !e.shiftKey) d = {wrap: "**"}
              else if (k === "i" && !e.shiftKey) d = {wrap: "*"}
              else if (k === "x" && e.shiftKey) d = {wrap: "~~"}
              if (!d) return
              e.preventDefault()
              this.apply(d)
            }
            window.addEventListener("keydown", this.onKey)

            // A small floating "link" popover over the mouse whenever text is
            // selected in a writing field — the discoverable path to linking.
            this.linkBtn = document.getElementById("selection-link")
            this.onMouseup = (e) => {
              if (this.linkBtn && this.linkBtn.contains(e.target)) return
              this.placeLinkBtn(e)
            }
            this.onKeyup = () => this.placeLinkBtn(null)
            this.onScroll = () => { if (this.linkBtn) this.linkBtn.hidden = true }
            document.addEventListener("mouseup", this.onMouseup)
            document.addEventListener("keyup", this.onKeyup)
            window.addEventListener("scroll", this.onScroll, {passive: true})

            // The panel's pick round-trips back here; wrap the stashed
            // selection as [[target]] / [[target|display text]].
            this.handleEvent("apply_link", ({target}) => {
              const p = this.pending
              this.pending = null
              const t = p &&
                document.querySelector(
                  `textarea[data-block-id="${p.blockId}"][data-field="${p.field}"],` +
                  `input[data-block-id="${p.blockId}"][data-field="${p.field}"]`
                )
              if (!t || !target) return
              const s = Math.min(p.s, t.value.length)
              const end = Math.min(p.end, t.value.length)
              const sel = t.value.slice(s, end)
              const text = !sel || sel.toLowerCase() === target.toLowerCase()
                ? `[[${target}]]`
                : `[[${target}|${sel}]]`
              t.setRangeText(text, s, end, "end")
              t.focus()
              t.dispatchEvent(new Event("input", {bubbles: true}))
            })
          },
          destroyed() {
            document.removeEventListener("focusin", this.onFocusin)
            document.removeEventListener("mousedown", this.onMousedown)
            document.removeEventListener("click", this.onClick)
            window.removeEventListener("keydown", this.onKey)
            document.removeEventListener("mouseup", this.onMouseup)
            document.removeEventListener("keyup", this.onKeyup)
            window.removeEventListener("scroll", this.onScroll)
          },
          // Stash which selection to wrap (by block id — the element may
          // remount while the panel is open), then let the server open it.
          openLinkPanel() {
            const t = this.field()
            if (!t) return
            const s = t.selectionStart ?? t.value.length
            const end = t.selectionEnd ?? s
            this.pending = {blockId: t.dataset.blockId, field: t.dataset.field, s, end}
            if (this.linkBtn) this.linkBtn.hidden = true
            this.pushEvent("open_link_panel", {text: t.value.slice(s, end)})
          },
          placeLinkBtn(e) {
            const b = this.linkBtn
            if (!b) return
            requestAnimationFrame(() => {
              const t = document.activeElement
              const ok = t && t.dataset && t.dataset.blockId &&
                (t.tagName === "TEXTAREA" || t.tagName === "INPUT") &&
                t.selectionStart !== t.selectionEnd
              if (!ok) { b.hidden = true; return }
              b.hidden = false
              const at = e
                ? {x: e.clientX, y: e.clientY}
                : {x: t.getBoundingClientRect().left + 40, y: t.getBoundingClientRect().top + 20}
              b.style.left =
                Math.min(Math.max(8, at.x - b.offsetWidth / 2), window.innerWidth - b.offsetWidth - 8) + "px"
              b.style.top = Math.max(8, at.y - b.offsetHeight - 12) + "px"
            })
          },
          // The remembered field, re-resolved by block id when the element
          // was remounted since focus (ids embed @bump, so undo/redo and
          // remote writes detach it); else the first field in the doc.
          field() {
            let t = this.target
            if (t && !t.isConnected) {
              t = document.querySelector(
                `textarea[data-block-id="${t.dataset.blockId}"][data-field="${t.dataset.field}"],` +
                `input[data-block-id="${t.dataset.blockId}"][data-field="${t.dataset.field}"]`
              )
              this.target = t
            }
            return t || document.querySelector("textarea[data-block-id], input[data-block-id]")
          },
          apply(d) {
            const t = this.field()
            if (!t) return
            const s = t.selectionStart ?? t.value.length
            const end = t.selectionEnd ?? s
            const put = (text, mode) => {
              if (t.setRangeText) {
                t.setRangeText(text, s, end, mode)
              } else {
                t.value = t.value.slice(0, s) + text + t.value.slice(end)
                const pos = mode === "start" ? s : s + text.length
                t.selectionStart = t.selectionEnd = pos
              }
            }

            if (d.char) {
              put(d.char, "end")
            } else if (d.wrap) {
              // Wrap the selection (or the caret) in a marker pair.
              put(d.wrap + t.value.slice(s, end) + d.wrap, "end")
            } else if (d.prefix) {
              // Prefix every selected line (bullets/numbering).
              const lines = t.value.slice(s, end).split("\n").map((l) => d.prefix + l).join("\n")
              put(lines || d.prefix, "end")
            } else {
              return
            }
            t.focus()
            // Nudge the block hook to debounce-save + resize.
            t.dispatchEvent(new Event("input", {bubbles: true}))
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

            // ⌘/Ctrl+Z = event-log undo, ⌘⇧Z or Ctrl+Y = redo. While the
            // caret is IN a block (a text field) the browser's native
            // undo/redo of just-typed text should win — those keystrokes
            // aren't committed as ops yet — so only intercept on page chrome.
            this.onKey = (e) => {
              if (!(e.metaKey || e.ctrlKey)) return
              const redo = (e.key === "z" && e.shiftKey) || e.key === "y"
              const undo = e.key === "z" && !e.shiftKey
              if (!undo && !redo) return
              const t = document.activeElement
              if (t && (t.tagName === "TEXTAREA" || t.tagName === "INPUT")) return
              e.preventDefault()
              this.pushEvent(redo ? "redo" : "undo")
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
