defmodule Uitstalling.Writing do
  @moduledoc """
  Private long-form writing: projects → docs (chapters / planning sheets) →
  blocks. See docs/writing.md for the full design.

  Three properties this module owns:

    * **Trust boundary** — `parse/2` validates every doc body the way
      `Decks.parse/1` validates decks: enum'd block types per doc kind,
      bounded sizes, no HTML, unique block ids. Nothing unvalidated is ever
      persisted or rendered.

    * **Event sourcing** — every change is an appended `writing_events` row
      (realized ops + inverse) plus a snapshot update in one transaction,
      CAS'd on the doc's `seq`. Undo appends the stored inverse as a new
      event; the timeline folds inverses backward from the current snapshot.

    * **Encryption** — all content (titles, bodies, event payloads) is
      ciphertext under a per-project DEK (`Uitstalling.Writing.Vault`).
      Decryption happens HERE and nowhere else; there is deliberately no
      code path handing plaintext to the agent layer.

  Docs are never public: every function that touches a doc takes the project
  and scopes queries to it, and callers gate on `owned_by?/2`.
  """

  import Ecto.Query

  alias Uitstalling.Repo
  alias Uitstalling.Writing.{Doc, Event, Image, Link, Op, Project, Vault}

  @doc_version 1

  @max_blocks 2_000
  @max_string_bytes 20_000
  @max_title_bytes 300

  # chapter = manuscript; planning = free-form sheet; element = one node of
  # the story world (a character, a faction, …) — a full doc like the others,
  # so elements get the same encrypted body, event log, and undo.
  @kinds ~w(chapter planning element)

  # Plan-element types are per-user now (docs/writing.md): a small always-on
  # CORE, a CURATED gallery the user opts into, and up to 5 custom types.
  # Each built-in maps to a color SLOT (a plain name); WritingComponents turns
  # a slot into Tailwind classes — custom types pick a slot too, which is what
  # keeps their colour inside Tailwind's build-time constraint.
  @core_element_types ~w(character location object)
  @curated_element_types ~w(family faction nation theme arc event creature organization)

  @element_type_catalog %{
    "character" => %{label: "character", color: "amber"},
    "location" => %{label: "location", color: "emerald"},
    "object" => %{label: "object", color: "sky"},
    "family" => %{label: "family", color: "fuchsia"},
    "faction" => %{label: "faction", color: "rose"},
    "nation" => %{label: "nation", color: "red"},
    "theme" => %{label: "theme", color: "violet"},
    "arc" => %{label: "arc", color: "indigo"},
    "event" => %{label: "event", color: "orange"},
    "creature" => %{label: "creature", color: "teal"},
    "organization" => %{label: "organization", color: "cyan"}
  }

  # Colour slots a custom type may choose from (all have Tailwind classes in
  # WritingComponents). The doc-kind fallbacks (chapter/planning) use their
  # own neutral slots and are not offered here.
  @color_slots ~w(amber emerald sky fuchsia rose red violet indigo orange teal cyan lime)

  # Colours for the non-element doc kinds, so the registry can render a
  # chapter/plan-map chip too.
  @kind_colors %{"chapter" => "stone", "planning" => "slate"}

  @max_custom_types 5

  # Reading-first surfaces: paper is the e-reader default (warm page, dark
  # ink), plain is pure black-on-white; the deck palettes come along adapted.
  @themes ~w(paper plain noir midnight blush pistachio powder)
  @fonts ~w(literata garamond source_serif georgia)

  # Block vocabulary. Manuscript types everywhere; plan maps (kind
  # "planning") add cards and placed "node" dots; elements add labeled
  # fields and the portrait slot. "id" and "type" are common to every block.
  @block_keys %{
    "paragraph" => ~w(text),
    "heading" => ~w(text),
    "scene_break" => ~w(),
    "epigraph" => ~w(text source),
    "character" => ~w(name text),
    "beat" => ~w(label text),
    "field" => ~w(label text),
    "portrait" => ~w(image caption),
    "node" => ~w(doc x y)
  }

  # Required = the key must be present as a string. Empty strings are fine —
  # a blank paragraph mid-typing is a normal document state, unlike decks.
  # (portrait and node have their own shape checks in validate_block/3.)
  @block_required %{
    "paragraph" => ~w(text),
    "heading" => ~w(text),
    "scene_break" => ~w(),
    "epigraph" => ~w(text),
    "character" => ~w(name),
    "beat" => ~w(label),
    "field" => ~w(label text),
    "portrait" => ~w(),
    "node" => ~w()
  }

  @manuscript_types ~w(paragraph heading scene_break epigraph)
  @planning_types ~w(paragraph heading scene_break epigraph character beat field node)
  @element_block_types ~w(paragraph heading beat field portrait)
  @kind_types %{
    "chapter" => @manuscript_types,
    "planning" => @planning_types,
    "element" => @element_block_types
  }

  # A plan-map dot may sit anywhere in this coordinate box.
  @map_extent 100_000

  # Word counting sums every prose-bearing field.
  @counted_fields ~w(text name label source)

  def kinds, do: @kinds
  def core_element_types, do: @core_element_types
  def curated_element_types, do: @curated_element_types
  def color_slots, do: @color_slots
  def max_custom_types, do: @max_custom_types

  @doc "Every built-in element type key (core ++ curated)."
  def builtin_element_types, do: @core_element_types ++ @curated_element_types

  @doc "The built-in catalog: `%{key => %{label, color}}` for core + curated."
  def element_type_catalog, do: @element_type_catalog

  @doc """
  The element types a user may create right now, ordered for the dropdown:
  core, then the curated ones they enabled, then their custom types. Each is
  `%{key, label, color}`.
  """
  def active_element_types(user) do
    settings = user_settings(user)
    enabled = MapSet.new(settings.enabled_element_types)

    core = Enum.map(@core_element_types, &catalog_entry/1)
    curated = for k <- @curated_element_types, MapSet.member?(enabled, k), do: catalog_entry(k)

    custom =
      for c <- settings.custom_element_types,
          do: %{key: c.key, label: c.label, color: c.color}

    core ++ curated ++ custom
  end

  @doc """
  Colour/label lookup for ANY type a doc might carry — every built-in (so an
  existing element of a not-currently-enabled type still renders its real
  colour), this user's custom types, plus the chapter/planning kind
  fallbacks. `%{key => %{label, color}}`.
  """
  def element_type_registry(user) do
    custom =
      for c <- user_settings(user).custom_element_types,
          into: %{},
          do: {c.key, %{label: c.label, color: c.color}}

    kinds = for {k, color} <- @kind_colors, into: %{}, do: {k, %{label: k, color: color}}

    @element_type_catalog |> Map.merge(custom) |> Map.merge(kinds)
  end

  defp catalog_entry(key) do
    %{label: @element_type_catalog[key].label, color: @element_type_catalog[key].color, key: key}
  end

  # Settings may be absent (older rows / never-saved) — treat as defaults.
  defp user_settings(%{settings: %Uitstalling.Accounts.UserSettings{} = s}), do: s
  defp user_settings(_user), do: %Uitstalling.Accounts.UserSettings{}

  def themes, do: @themes
  def fonts, do: @fonts
  def block_types(kind), do: @kind_types[kind] || []
  def block_keys(type), do: @block_keys[type]
  def block_required(type), do: @block_required[type] || []

  @doc "A fresh URL-safe id (projects and docs)."
  def generate_id do
    Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
  end

  # ----- Projects -----------------------------------------------------------------

  @doc "Create a project owned by `user_id`, minting and wrapping its DEK."
  def create_project(user_id, title, attrs \\ %{}) do
    with {:ok, title} <- clean_title(title) do
      id = generate_id()
      dek = Vault.generate_dek()
      {kek_id, wrapped} = Vault.wrap_dek(dek, id)

      Repo.insert!(%Project{
        id: id,
        user_id: user_id,
        title_enc: Vault.encrypt(dek, title, id),
        dek_wrapped: wrapped,
        kek_id: kek_id,
        theme: validate_enum(attrs[:theme], @themes, "paper"),
        font: validate_enum(attrs[:font], @fonts, "literata")
      })

      {:ok, id}
    end
  end

  @doc "The project row, scoped to its owner. Raises if it isn't theirs."
  def get_project!(project_id, user_id) do
    Repo.one!(from(p in Project, where: p.id == ^project_id and p.user_id == ^user_id))
  end

  def owned_by?(_project_id, nil), do: false

  def owned_by?(project_id, user_id) do
    Repo.exists?(from(p in Project, where: p.id == ^project_id and p.user_id == ^user_id))
  end

  @doc "The project's decrypted title."
  def project_title(%Project{} = project) do
    {:ok, title} = Vault.decrypt(dek(project), project.title_enc, project.id)
    title
  end

  @doc """
  A user's projects for the shelf, newest-touched first:
  `%{id, title, theme, font, chapters, words, updated_at}`.
  """
  def list_projects(user_id) do
    stats =
      from(d in Doc,
        group_by: d.project_id,
        select:
          {d.project_id,
           %{
             chapters: filter(count(d.id), d.kind == "chapter"),
             # The manuscript count — planning sheets and elements are
             # worldbuilding, not the novel.
             words: filter(sum(d.word_count), d.kind == "chapter")
           }}
      )
      |> Repo.all()
      |> Map.new()

    from(p in Project, where: p.user_id == ^user_id, order_by: [desc: p.updated_at])
    |> Repo.all()
    |> Enum.map(fn project ->
      stat = stats[project.id] || %{chapters: 0, words: 0}

      %{
        id: project.id,
        title: project_title(project),
        theme: project.theme,
        font: project.font,
        chapters: stat.chapters,
        words: stat.words || 0,
        updated_at: project.updated_at
      }
    end)
  end

  @doc "Rename a project."
  def rename_project(%Project{} = project, title) do
    with {:ok, title} <- clean_title(title) do
      project
      |> Ecto.Changeset.change(title_enc: Vault.encrypt(dek(project), title, project.id))
      |> Repo.update!()

      :ok
    end
  end

  @doc "Set the project's reading theme."
  def set_theme(%Project{} = project, theme) when theme in @themes do
    project |> Ecto.Changeset.change(theme: theme) |> Repo.update!()
    :ok
  end

  @doc "Set the project's font."
  def set_font(%Project{} = project, font) when font in @fonts do
    project |> Ecto.Changeset.change(font: font) |> Repo.update!()
    :ok
  end

  @doc "Delete a project and everything under it (docs and events cascade)."
  def delete_project(%Project{} = project) do
    Repo.delete!(project)
    :ok
  end

  @doc """
  Re-wrap every project DEK under the active KEK — run from IEx after adding
  a new first entry to WRITING_MASTER_KEYS. Content is not touched; only the
  small wrapped keys are re-encrypted. Returns the number rotated.
  """
  def rotate_project_keys! do
    active = Vault.active_kek_id()

    from(p in Project, where: p.kek_id != ^active)
    |> Repo.all()
    |> Enum.map(fn project ->
      dek = Vault.unwrap_dek(project.kek_id, project.dek_wrapped, project.id)
      {kek_id, wrapped} = Vault.wrap_dek(dek, project.id)

      project
      |> Ecto.Changeset.change(kek_id: kek_id, dek_wrapped: wrapped)
      |> Repo.update!()
    end)
    |> length()
  end

  # ----- Docs ----------------------------------------------------------------------

  @doc """
  Create a doc under a project. A fresh doc is one empty paragraph — a page
  ready to type on. Appends the `doc.created` event (seq 1) so the timeline
  has a t₀. Element docs must say which `element_type:` they are.
  """
  def create_doc(%Project{} = project, kind, title, opts \\ []) when kind in @kinds do
    with {:ok, staged} <- stage_doc(project, kind, title, opts),
         id = generate_id(),
         {:ok, _meta} <- persist_staged_doc(project, id, staged) do
      {:ok, id}
    end
  end

  @doc """
  Create a plan element (a doc of kind \"element\") — its title is its name.
  `type` is validated structurally here; whether it's a type THIS user may
  use is gated at the LiveView (which knows the current user's active set),
  matching the app's authz-at-the-edge, structural-in-the-context split.
  """
  def create_element(%Project{} = project, type, name) do
    create_doc(project, "element", name, element_type: type)
  end

  @doc """
  Everything about a new doc that can be decided without the database —
  validated title, kind, and the initial body. The ProjectServer stages,
  replies to its caller, THEN persists (`persist_staged_doc/3`), so creating
  feels instant on a slow machine while staying validated up front.
  """
  def stage_doc(%Project{}, kind, title, opts) when kind in @kinds do
    element_type = opts[:element_type]

    with {:ok, title} <- clean_title(title),
         :ok <- check_element_type(kind, element_type) do
      raw = migrate(%{"blocks" => initial_blocks(kind, element_type)})
      {:ok, _} = parse(raw, kind)

      {:ok, %{kind: kind, element_type: element_type, title: title, raw: raw}}
    end
  end

  @doc "Insert a staged doc under `id`. Returns its `list_docs/1`-shaped meta row."
  def persist_staged_doc(%Project{} = project, id, staged) do
    dek = dek(project)

    position =
      Repo.one(
        from(d in Doc,
          where: d.project_id == ^project.id and d.kind == ^staged.kind,
          select: coalesce(max(d.position), -1)
        )
      ) + 1

    {:ok, doc} =
      Repo.transaction(fn ->
        doc =
          Repo.insert!(%Doc{
            id: id,
            project_id: project.id,
            kind: staged.kind,
            element_type: staged.element_type,
            position: position,
            title_enc: Vault.encrypt(dek, staged.title, id),
            data_enc: encrypt_map(dek, staged.raw, id),
            seq: 1,
            word_count: 0
          })

        insert_event!(dek, id, 1, "doc.created", "system", "editor", nil, %{"doc" => staged.raw})

        doc
      end)

    {:ok,
     %{
       id: id,
       kind: staged.kind,
       element_type: staged.element_type,
       title: staged.title,
       position: position,
       seq: 1,
       word_count: 0,
       updated_at: doc.updated_at
     }}
  rescue
    e -> {:error, e}
  end

  # Structural only — a non-empty slug-shaped key up to 32 chars (built-in or
  # custom). "Is this a type the user may create" is the LiveView's call.
  defp check_element_type("element", type)
       when is_binary(type) and byte_size(type) in 1..32 do
    if type =~ ~r/^[a-z][a-z0-9_]*$/, do: :ok, else: {:error, ["element_type: invalid"]}
  end

  defp check_element_type("element", _type), do: {:error, ["element_type: required"]}
  defp check_element_type(_kind, nil), do: :ok

  defp check_element_type(_kind, _type),
    do: {:error, ["element_type: only element docs have one"]}

  # What a fresh page holds. Characters open as a profile — portrait slot and
  # the sheets a novelist actually keeps — instead of a blank paragraph.
  # Plan maps open empty: the canvas palette is the entry point.
  defp initial_blocks("element", "character") do
    [
      %{"type" => "portrait"},
      %{"type" => "field", "label" => "Background", "text" => ""},
      %{"type" => "field", "label" => "Physicality", "text" => ""},
      %{"type" => "field", "label" => "Traits", "text" => ""},
      %{"type" => "paragraph", "text" => ""}
    ]
  end

  defp initial_blocks("planning", _type), do: []
  defp initial_blocks(_kind, _type), do: [%{"type" => "paragraph", "text" => ""}]

  @doc "A project's docs: `%{id, kind, title, position, seq, word_count, updated_at}`."
  def list_docs(%Project{} = project) do
    dek = dek(project)

    from(d in Doc,
      where: d.project_id == ^project.id,
      order_by: [asc: d.kind, asc: d.position]
    )
    |> Repo.all()
    |> Enum.map(fn doc ->
      {:ok, title} = Vault.decrypt(dek, doc.title_enc, doc.id)

      %{
        id: doc.id,
        kind: doc.kind,
        element_type: doc.element_type,
        title: title,
        position: doc.position,
        seq: doc.seq,
        word_count: doc.word_count,
        updated_at: doc.updated_at
      }
    end)
  end

  @doc "The doc row, scoped to its project. Raises if it isn't the project's."
  def get_doc!(%Project{} = project, doc_id) do
    Repo.one!(from(d in Doc, where: d.id == ^doc_id and d.project_id == ^project.id))
  end

  @doc "Decrypted body + CAS seq + decrypted title — what an editor mounts with."
  def checkout_doc(%Project{} = project, doc_id) do
    doc = get_doc!(project, doc_id)
    dek = dek(project)
    {:ok, title} = Vault.decrypt(dek, doc.title_enc, doc.id)
    {migrate(decrypt_map!(dek, doc.data_enc, doc.id)), doc.seq, title}
  end

  @doc "Delete one doc (its events cascade)."
  def delete_doc(%Project{} = project, doc_id) do
    Repo.delete!(get_doc!(project, doc_id))
    :ok
  end

  @doc "Reorder a doc among its kind (plain metadata, not an event)."
  def move_doc(%Project{} = project, doc_id, position) when is_integer(position) do
    get_doc!(project, doc_id)
    |> Ecto.Changeset.change(position: position)
    |> Repo.update!()

    :ok
  end

  # ----- Links (plan mode) -----------------------------------------------------------
  #
  # Chapter→element tags and element→element relations, one table. Stored
  # directed, displayed undirected; idempotent either way around. Links are
  # shelf-keeping metadata, not writing — they live outside the event log.

  @doc "Link two docs of this project. Idempotent; refuses self-links."
  def link(%Project{} = project, source_id, target_id) do
    cond do
      source_id == target_id ->
        {:error, :self_link}

      not both_in_project?(project, source_id, target_id) ->
        {:error, :not_found}

      linked?(project, source_id, target_id) ->
        :ok

      true ->
        Repo.insert!(%Link{
          project_id: project.id,
          source_id: source_id,
          target_id: target_id,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

        :ok
    end
  end

  @doc "Remove the link between two docs, whichever way it was stored."
  def unlink(%Project{} = project, a, b) do
    Repo.delete_all(pair_query(project, a, b))
    :ok
  end

  @doc "Whether two docs are linked (either direction)."
  def linked?(%Project{} = project, a, b) do
    Repo.exists?(pair_query(project, a, b))
  end

  @doc """
  Every doc linked to `doc_id`, both directions, with decrypted titles:
  `%{id, kind, element_type, title}` — elements first (by type, then name),
  then chapters in book order.
  """
  def linked_docs(%Project{} = project, doc_id) do
    dek = dek(project)

    other =
      from(l in Link,
        where: l.project_id == ^project.id,
        where: l.source_id == ^doc_id or l.target_id == ^doc_id,
        select: {l.source_id, l.target_id}
      )
      |> Repo.all()
      |> Enum.map(fn {s, t} -> if s == doc_id, do: t, else: s end)

    from(d in Doc, where: d.id in ^other)
    |> Repo.all()
    |> Enum.map(fn doc ->
      {:ok, title} = Vault.decrypt(dek, doc.title_enc, doc.id)

      %{
        id: doc.id,
        kind: doc.kind,
        element_type: doc.element_type,
        title: title,
        position: doc.position
      }
    end)
    |> Enum.sort_by(fn doc ->
      case doc.kind do
        "element" -> {0, doc.element_type, doc.title}
        kind -> {1, kind, doc.position}
      end
    end)
    |> Enum.map(&Map.delete(&1, :position))
  end

  @doc """
  The project's story map: every element, plus every chapter/sheet that has
  at least one link. `%{nodes: [%{id, title, type}], edges: [...]}` where
  `type` is the element type or the doc kind.
  """
  def graph(%Project{} = project) do
    dek = dek(project)

    edges =
      from(l in Link, where: l.project_id == ^project.id, select: {l.source_id, l.target_id})
      |> Repo.all()

    linked_ids = edges |> Enum.flat_map(fn {s, t} -> [s, t] end) |> MapSet.new()

    nodes =
      from(d in Doc, where: d.project_id == ^project.id)
      |> Repo.all()
      |> Enum.filter(fn doc -> doc.kind == "element" or MapSet.member?(linked_ids, doc.id) end)
      |> Enum.map(fn doc ->
        {:ok, title} = Vault.decrypt(dek, doc.title_enc, doc.id)
        %{id: doc.id, title: title, type: doc.element_type || doc.kind}
      end)

    %{nodes: nodes, edges: Enum.map(edges, fn {s, t} -> %{source: s, target: t} end)}
  end

  defp pair_query(project, a, b) do
    from(l in Link,
      where: l.project_id == ^project.id,
      where:
        (l.source_id == ^a and l.target_id == ^b) or (l.source_id == ^b and l.target_id == ^a)
    )
  end

  defp both_in_project?(project, a, b) do
    Repo.aggregate(
      from(d in Doc, where: d.project_id == ^project.id and d.id in ^[a, b]),
      :count
    ) == 2
  end

  # ----- Images (portraits/sketches) ---------------------------------------------------
  #
  # Deliberately NOT the public assets bucket: writing is private, so image
  # bytes are ciphertext under the project DEK and only the owner-gated
  # writing image route can serve them. Blocks reference images by id;
  # replaced images keep their rows (the event log may restore them on undo).

  @max_image_bytes 3_000_000
  @image_magic [
    {<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>, "image/png"},
    {<<0xFF, 0xD8, 0xFF>>, "image/jpeg"},
    {<<"RIFF">>, "image/webp"}
  ]

  @doc """
  Store an uploaded portrait/sketch, encrypted, sniffing the real content
  type from magic bytes (the client's claim is ignored). Returns
  `{:ok, image_id}` or `{:error, message}`.
  """
  def put_image(%Project{} = project, binary) when is_binary(binary) do
    cond do
      byte_size(binary) > @max_image_bytes ->
        {:error, "image is too large (3 MB max)"}

      content_type = sniff_image(binary) ->
        id = "wi" <> generate_id()

        Repo.insert!(%Image{
          id: id,
          project_id: project.id,
          content_type: content_type,
          byte_size: byte_size(binary),
          data_enc: Vault.encrypt(dek(project), binary, id),
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

        {:ok, id}

      true ->
        {:error, "not a PNG, JPEG, or WebP image"}
    end
  end

  @doc "Decrypt a stored image, scoped to its project. `{content_type, bytes}` or nil."
  def get_image(%Project{} = project, image_id) do
    case Repo.one(from(i in Image, where: i.id == ^image_id and i.project_id == ^project.id)) do
      nil ->
        nil

      image ->
        {:ok, bytes} = Vault.decrypt(dek(project), image.data_enc, image.id)
        {image.content_type, bytes}
    end
  end

  defp sniff_image(binary) do
    Enum.find_value(@image_magic, fn {magic, content_type} ->
      if match_magic?(binary, magic, content_type), do: content_type
    end)
  end

  # WebP needs the RIFF container AND the WEBP fourcc at offset 8.
  defp match_magic?(binary, magic, "image/webp") do
    binary_part_safe(binary, 0, 4) == magic and binary_part_safe(binary, 8, 4) == "WEBP"
  end

  defp match_magic?(binary, magic, _type) do
    binary_part_safe(binary, 0, byte_size(magic)) == magic
  end

  defp binary_part_safe(binary, start, len) do
    if byte_size(binary) >= start + len, do: binary_part(binary, start, len)
  end

  # ----- The write path (events) ----------------------------------------------------

  @doc """
  Apply an op batch to a doc: validate the result, then append the event and
  update the snapshot in one transaction, CAS'd on `expected_seq`.

  Returns `{:ok, new_raw, new_seq}`, `{:error, :stale}` when another writer
  landed since checkout (reload, never overwrite), or `{:error, [message]}`
  when the ops don't apply / the result breaks the schema.
  """
  def apply_ops(%Project{} = project, doc_id, ops, expected_seq, actor, source \\ "editor") do
    doc = get_doc!(project, doc_id)
    dek = dek(project)
    raw = migrate(decrypt_map!(dek, doc.data_enc, doc.id))

    with {:ok, new_raw, applied, inverse} <- Op.apply_batch(raw, ops),
         new_raw = migrate(new_raw),
         {:ok, _} <- parse(new_raw, doc.kind) do
      payload = %{
        "ops" => Enum.map(applied, &Op.dump/1),
        "inverse" => Enum.map(inverse, &Op.dump/1)
      }

      commit_event(dek, doc, new_raw, expected_seq, "ops.applied", actor, source, nil, payload)
    end
  end

  @doc """
  Undo the most recent not-yet-undone edit by appending its stored inverse
  as a new event (history only grows — git-revert style). Repeated undos
  walk further back. Returns like `apply_ops/6`, or `{:error, :nothing_to_undo}`.
  """
  def undo(%Project{} = project, doc_id, expected_seq, actor) do
    doc = get_doc!(project, doc_id)
    dek = dek(project)

    case undo_target(doc.id) do
      nil ->
        {:error, :nothing_to_undo}

      target ->
        payload = decrypt_map!(dek, target.payload_enc, event_aad(doc.id, target.seq))
        inverse_ops = Enum.map(payload["inverse"], &Op.load/1)
        raw = migrate(decrypt_map!(dek, doc.data_enc, doc.id))

        with {:ok, new_raw, applied, inverse} <- Op.apply_batch(raw, inverse_ops),
             new_raw = migrate(new_raw),
             {:ok, _} <- parse(new_raw, doc.kind) do
          undo_payload = %{
            "ops" => Enum.map(applied, &Op.dump/1),
            "inverse" => Enum.map(inverse, &Op.dump/1)
          }

          commit_event(
            dek,
            doc,
            new_raw,
            expected_seq,
            "undo",
            actor,
            "undo",
            target.seq,
            undo_payload
          )
        end
    end
  end

  @doc "Rename a doc — an event like any other change (CAS'd, in the timeline)."
  def rename_doc(%Project{} = project, doc_id, title, expected_seq, actor) do
    with {:ok, title} <- clean_title(title) do
      doc = get_doc!(project, doc_id)
      dek = dek(project)
      {:ok, was} = Vault.decrypt(dek, doc.title_enc, doc.id)

      result =
        Repo.transaction(fn ->
          insert_event!(dek, doc.id, expected_seq + 1, "title.set", actor, "editor", nil, %{
            "title" => title,
            "was" => was
          })

          updated =
            Repo.update_all(
              from(d in Doc, where: d.id == ^doc.id and d.seq == ^expected_seq),
              set: [
                title_enc: Vault.encrypt(dek, title, doc.id),
                seq: expected_seq + 1,
                updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
              ]
            )

          case updated do
            {1, _} -> expected_seq + 1
            {0, _} -> Repo.rollback(:stale)
          end
        end)

      case result do
        {:ok, seq} -> {:ok, title, seq}
        {:error, :stale} -> {:error, :stale}
      end
    end
  rescue
    e in Ecto.ConstraintError ->
      if seq_conflict?(e), do: {:error, :stale}, else: reraise(e, __STACKTRACE__)
  end

  # Append + snapshot update in ONE transaction. The (doc_id, seq) unique
  # index and the seq-guarded update are the same lock seen from both sides:
  # either way a concurrent writer surfaces as {:error, :stale}.
  defp commit_event(
         dek,
         %Doc{} = doc,
         new_raw,
         expected_seq,
         type,
         actor,
         source,
         undoes,
         payload
       ) do
    words = count_words(new_raw)

    result =
      Repo.transaction(fn ->
        insert_event!(dek, doc.id, expected_seq + 1, type, actor, source, undoes, payload)

        updated =
          Repo.update_all(
            from(d in Doc, where: d.id == ^doc.id and d.seq == ^expected_seq),
            set: [
              data_enc: encrypt_map(dek, new_raw, doc.id),
              seq: expected_seq + 1,
              word_count: words,
              updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            ]
          )

        case updated do
          {1, _} -> :ok
          {0, _} -> Repo.rollback(:stale)
        end
      end)

    case result do
      {:ok, :ok} -> {:ok, new_raw, expected_seq + 1}
      {:error, :stale} -> {:error, :stale}
    end
  rescue
    e in Ecto.ConstraintError ->
      if seq_conflict?(e), do: {:error, :stale}, else: reraise(e, __STACKTRACE__)
  end

  defp insert_event!(dek, doc_id, seq, type, actor, source, undoes, payload) do
    Repo.insert!(%Event{
      doc_id: doc_id,
      seq: seq,
      type: type,
      actor: actor,
      source: source,
      undoes: undoes,
      payload_enc: encrypt_map(dek, payload, event_aad(doc_id, seq)),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  # A racing writer can land between our seq read and the insert — the unique
  # index turns that into a constraint error, which is just :stale by another
  # name. Anything else re-raises at the rescue site.
  defp seq_conflict?(%Ecto.ConstraintError{constraint: constraint}),
    do: constraint == "writing_events_doc_id_seq_index"

  # The most recent content event not cancelled by a live undo. Undos cancel
  # their target; a cancelled undo releases its target (that's redo, when the
  # timeline UI wants it).
  defp undo_target(doc_id) do
    events =
      Repo.all(
        from(e in Event,
          where: e.doc_id == ^doc_id and e.type in ["ops.applied", "undo"],
          order_by: [desc: e.seq]
        )
      )

    cancelled =
      Enum.reduce(events, MapSet.new(), fn event, cancelled ->
        if event.type == "undo" and not MapSet.member?(cancelled, event.seq),
          do: MapSet.put(cancelled, event.undoes),
          else: cancelled
      end)

    Enum.find(events, fn event ->
      event.type == "ops.applied" and not MapSet.member?(cancelled, event.seq)
    end)
  end

  # ----- Timeline --------------------------------------------------------------------

  @doc "Event metadata for the timeline, newest first. No decryption needed."
  def events(%Project{} = project, doc_id) do
    doc = get_doc!(project, doc_id)

    Repo.all(
      from(e in Event,
        where: e.doc_id == ^doc.id,
        order_by: [desc: e.seq],
        select: %{
          seq: e.seq,
          type: e.type,
          actor: e.actor,
          source: e.source,
          undoes: e.undoes,
          inserted_at: e.inserted_at
        }
      )
    )
  end

  @doc """
  The doc body as of event `seq`: fold stored inverses backward from the
  current snapshot. Seq 1 is `doc.created` — the initial body.
  """
  def doc_at(%Project{} = project, doc_id, seq) when is_integer(seq) and seq >= 1 do
    doc = get_doc!(project, doc_id)
    dek = dek(project)
    raw = migrate(decrypt_map!(dek, doc.data_enc, doc.id))

    from(e in Event,
      where: e.doc_id == ^doc.id and e.seq > ^seq,
      order_by: [desc: e.seq]
    )
    |> Repo.all()
    |> Enum.reduce_while({:ok, raw}, fn event, {:ok, acc_raw} ->
      payload = decrypt_map!(dek, event.payload_enc, event_aad(doc.id, event.seq))

      case payload["inverse"] do
        nil ->
          # title.set and friends don't touch the body.
          {:cont, {:ok, acc_raw}}

        inverse ->
          case Op.apply_batch(acc_raw, Enum.map(inverse, &Op.load/1)) do
            {:ok, new_raw, _applied, _inverse} -> {:cont, {:ok, migrate(new_raw)}}
            {:error, errors} -> {:halt, {:error, errors}}
          end
      end
    end)
  end

  # ----- Words -------------------------------------------------------------------------

  @doc "Words across every prose-bearing field of the doc."
  def count_words(%{"blocks" => blocks}) when is_list(blocks) do
    Enum.sum(
      for %{} = block <- blocks, field <- @counted_fields, is_binary(block[field]) do
        block[field] |> String.split(~r/\s+/, trim: true) |> length()
      end
    )
  end

  def count_words(_raw), do: 0

  # ----- Validation (the trust boundary) --------------------------------------------------

  @doc """
  Validate a raw doc body for its kind. Returns `{:ok, raw}` or
  `{:error, [path-prefixed message]}` — same contract as `Decks.parse/1`.
  """
  def parse(%{} = raw, kind) when kind in @kinds do
    case validate(raw, kind) do
      [] -> {:ok, raw}
      errors -> {:error, errors}
    end
  end

  def parse(_raw, kind) when kind in @kinds, do: {:error, ["top level: must be a JSON object"]}

  @doc """
  Upgrade a stored raw body to the current document version. Pure and
  idempotent; applied on every load and before every save. Current
  migrations: stamp "v", backfill missing/duplicate block ids ("bN").
  """
  def migrate(%{} = raw) do
    raw
    |> Map.put("v", @doc_version)
    |> Map.update("blocks", [], fn
      blocks when is_list(blocks) -> ensure_ids(blocks)
      other -> other
    end)
  end

  defp validate(raw, kind) do
    case raw["blocks"] do
      blocks when is_list(blocks) and length(blocks) <= @max_blocks ->
        types = @kind_types[kind]

        blocks
        |> Enum.with_index()
        |> Enum.flat_map(fn {block, i} -> validate_block(block, types, i) end)
        |> Kernel.++(duplicate_id_errors(blocks))

      blocks when is_list(blocks) ->
        ["doc.blocks: must have at most #{@max_blocks} blocks"]

      _ ->
        ["doc.blocks: must be a list"]
    end
  end

  defp validate_block(%{} = block, types, i) do
    path = "blocks[#{i}]"

    case block["type"] do
      type when is_binary(type) ->
        if type in types do
          unknown = Map.keys(block) -- (~w(id type) ++ @block_keys[type])

          unknown_errors =
            if unknown == [],
              do: [],
              else: ["#{path}: unknown keys #{inspect(unknown)} for type \"#{type}\""]

          unknown_errors ++ opt_string(block, "id", path) ++ validate_fields(type, block, path)
        else
          ["#{path}.type: #{inspect(type)} must be one of: #{Enum.join(types, ", ")}"]
        end

      other ->
        ["#{path}.type: #{inspect(other)} must be one of: #{Enum.join(types, ", ")}"]
    end
  end

  defp validate_block(_block, _types, i), do: ["blocks[#{i}]: must be an object"]

  # A plan-map dot: which doc it stands for, and where it sits.
  defp validate_fields("node", block, path) do
    doc_errors =
      case block["doc"] do
        d when is_binary(d) and d != "" -> []
        _ -> ["#{path}.doc: required doc id string"]
      end

    coord_errors =
      for key <- ~w(x y),
          not (is_number(block[key]) and block[key] >= 0 and block[key] <= @map_extent) do
        "#{path}.#{key}: must be a number between 0 and #{@map_extent}"
      end

    doc_errors ++ coord_errors
  end

  # A portrait slot: empty, or referencing a stored writing image by id.
  # Existence is a render concern (a deleted image degrades to the slot) —
  # like deck assets, parse/1 stays free of DB access.
  defp validate_fields("portrait", block, path) do
    image_errors =
      case block["image"] do
        nil ->
          []

        "" ->
          []

        id when is_binary(id) ->
          if id =~ ~r/^wi[a-f0-9]{10}$/, do: [], else: ["#{path}.image: not a valid image id"]

        _ ->
          ["#{path}.image: must be an image id string"]
      end

    image_errors ++ optional_strings(block, ~w(caption), path)
  end

  defp validate_fields(type, block, path) do
    required_strings(block, @block_required[type], path) ++
      optional_strings(block, @block_keys[type] -- @block_required[type], path)
  end

  defp required_strings(block, keys, path) do
    Enum.flat_map(keys, fn key ->
      case block[key] do
        s when is_binary(s) -> check_text(s, "#{path}.#{key}")
        _ -> ["#{path}.#{key}: required string (may be empty)"]
      end
    end)
  end

  defp optional_strings(block, keys, path) do
    Enum.flat_map(keys, fn key ->
      case block[key] do
        nil -> []
        s when is_binary(s) -> check_text(s, "#{path}.#{key}")
        _ -> ["#{path}.#{key}: must be a string"]
      end
    end)
  end

  defp opt_string(block, key, path) do
    case block[key] do
      nil -> []
      s when is_binary(s) and s != "" -> []
      _ -> ["#{path}.#{key}: must be a non-empty string"]
    end
  end

  # Bounded size and the no-HTML rule. Prose markup is **strong**, *em*,
  # ~~strike~~, and newlines — rendered run-by-run and escaped, never HTML.
  defp check_text(s, path) do
    size_errors =
      if byte_size(s) <= @max_string_bytes,
        do: [],
        else: ["#{path}: must be at most #{@max_string_bytes} bytes"]

    html_errors =
      if s =~ ~r{</?[a-zA-Z][a-zA-Z0-9-]*(\s[^>]*)?>},
        do: ["#{path}: HTML tags are not allowed — use **strong**, *em*, ~~strike~~"],
        else: []

    size_errors ++ html_errors
  end

  defp duplicate_id_errors(blocks) do
    ids = for %{} = block <- blocks, is_binary(block["id"]), do: block["id"]

    case Enum.uniq(ids -- Enum.uniq(ids)) do
      [] -> []
      dups -> ["doc.blocks: duplicate block ids #{inspect(dups)} — every id must be unique"]
    end
  end

  # Give every block a unique string id, preserving existing unique ones —
  # the Decks.migrate/1 approach on a flat list.
  defp ensure_ids(blocks) do
    taken =
      for %{} = block <- blocks,
          is_binary(block["id"]) and block["id"] != "",
          into: MapSet.new(),
          do: block["id"]

    {blocks, _seen} =
      blocks
      |> Enum.with_index()
      |> Enum.map_reduce(MapSet.new(), fn {block, i}, seen ->
        case block do
          %{"id" => id} when is_binary(id) and id != "" ->
            if MapSet.member?(seen, id),
              do:
                {Map.put(block, "id", mint_id(i, MapSet.union(taken, seen))),
                 MapSet.put(seen, id)},
              else: {block, MapSet.put(seen, id)}

          %{} ->
            id = mint_id(i, MapSet.union(taken, seen))
            {Map.put(block, "id", id), MapSet.put(seen, id)}

          other ->
            {other, seen}
        end
      end)

    blocks
  end

  defp mint_id(i, taken) do
    id = "b#{i}"
    if MapSet.member?(taken, id), do: mint_id(i + 1, taken), else: id
  end

  # ----- Crypto plumbing -----------------------------------------------------------------

  # Unwrapping is per-call on purpose: the DEK lives only as long as the
  # request that needed it. If profiling ever cares, memoize per-process.
  defp dek(%Project{} = project),
    do: Vault.unwrap_dek(project.kek_id, project.dek_wrapped, project.id)

  defp encrypt_map(dek, %{} = map, aad), do: Vault.encrypt(dek, Jason.encode!(map), aad)

  defp decrypt_map!(dek, blob, aad) do
    {:ok, json} = Vault.decrypt(dek, blob, aad)
    Jason.decode!(json)
  end

  defp event_aad(doc_id, seq), do: "#{doc_id}:#{seq}"

  defp clean_title(title) when is_binary(title) do
    title = String.trim(title)

    cond do
      title == "" -> {:error, ["title: required"]}
      byte_size(title) > @max_title_bytes -> {:error, ["title: too long"]}
      true -> {:ok, title}
    end
  end

  defp clean_title(_title), do: {:error, ["title: required"]}

  defp validate_enum(value, allowed, default) do
    if value in allowed, do: value, else: default
  end
end
