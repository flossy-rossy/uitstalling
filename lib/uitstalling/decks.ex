defmodule Uitstalling.Decks do
  @moduledoc """
  The slide AST: parses untrusted deck JSON into structs the renderer can trust.

  Decks are produced by an LLM (or a human) as JSON — nothing in them is ever
  rendered as raw HTML. Text fields carry a tiny inline markup (`**strong**`,
  `==accent==`, `~~strike~~`, `` `code` ``, newlines) which the renderer parses
  and escapes run-by-run. Everything else is an enum or a shape check here, so
  a generation cannot express anything outside the design system: unknown
  layouts, unknown keys, off-palette colours and non-https media sources are
  all rejected.

  Validation errors are plain, path-prefixed strings (`slides[3].steps[1]: ...`)
  designed to be fed straight back to the model as a retry prompt.
  """

  alias Uitstalling.Decks.{BlockPath, Deck, Op, Slide}

  # Current document version, stamped by migrate/1. Bump when a stored deck
  # needs upgrading before it can pass the current validator.
  @doc_version 1

  # Ceilings on what a generation (or import) may contain. Generous for real
  # decks, tight enough that a runaway model can't persist megabytes.
  @max_slides 40
  @max_list_items 24
  @max_string_bytes 4_000

  @accents ~w(amber sky emerald rose violet cyan)
  @tones ~w(default accent danger light)
  @flow_colors ~w(zinc sky emerald amber rose)
  @tints ~w(none ok warn bad)
  @media_kinds ~w(image video)

  @sizes ~w(sm md lg)
  @themes ~w(noir midnight blush pistachio powder)

  # The accent each theme is designed around — theme switches re-pair the
  # accent so ==marks== and kickers stay legible on the new base.
  @theme_accents %{
    "noir" => "amber",
    "midnight" => "cyan",
    "blush" => "rose",
    "pistachio" => "emerald",
    "powder" => "sky"
  }

  # Keys every slide may carry, regardless of layout.
  @common_keys ~w(id layout tone size kicker footnote notes)

  # Keys the APP manages on a slide — valid in the document, but the model is
  # told never to emit them and the pipeline strips-and-restores them around
  # every agent edit. "image" references a stored asset by id (the model can't
  # hallucinate one into existence; the UI attaches them).
  @app_keys ~w(image)
  @image_treatments ~w(side full)

  # Layout-specific keys. Anything outside common + these is rejected —
  # strictness is the point: the model picks from the design system,
  # it does not extend it.
  @layout_keys %{
    "title" => ~w(heading subheading),
    "statement" => ~w(heading body),
    "bullets" => ~w(heading columns),
    "points" => ~w(heading points),
    "flow" => ~w(heading steps terminal),
    "big_code" => ~w(heading code body),
    "table" => ~w(heading columns rows),
    "media" => ~w(heading kind src caption),
    "faq" => ~w(heading items)
  }
  @layouts Map.keys(@layout_keys)

  # Which of a layout's keys the validator requires — kept next to
  # @layout_keys so schema_prompt/0 can state requiredness instead of letting
  # the model discover it by burning a retry.
  @layout_required %{
    "title" => ~w(heading),
    "statement" => ~w(body),
    "bullets" => ~w(heading columns),
    "points" => ~w(heading points),
    "flow" => ~w(steps),
    "big_code" => ~w(code),
    "table" => ~w(columns rows),
    "media" => ~w(kind),
    "faq" => ~w(items)
  }

  def accents, do: @accents
  def tones, do: @tones
  def flow_colors, do: @flow_colors
  def layouts, do: @layouts
  def themes, do: @themes

  @doc "The accent a theme is designed around."
  def theme_accent(theme), do: @theme_accents[theme] || "amber"

  @doc """
  Parse untrusted deck JSON (a string or an already-decoded map).

  Returns `{:ok, %Deck{}}` or `{:error, [error_message]}`.
  """
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> parse(map)
      {:ok, _other} -> {:error, ["top level: must be a JSON object"]}
      {:error, err} -> {:error, ["invalid JSON: #{Exception.message(err)}"]}
    end
  end

  def parse(%{} = map) do
    case validate(map) do
      [] -> {:ok, build(map)}
      errors -> {:error, errors}
    end
  end

  @doc """
  Whether the deck carries any playable video — the one thing a PDF export
  can't hold, so the UI warns before downloading.
  """
  def has_video?(%Deck{slides: slides}) do
    Enum.any?(slides, fn %Slide{layout: layout, fields: fields} ->
      layout == "media" and fields["kind"] == "video" and is_binary(fields["src"])
    end)
  end

  @doc """
  The design system described for the generation model, derived from the same
  module attributes the validator enforces — one source of truth for schema,
  validator, and prompt.
  """
  def schema_prompt do
    layouts =
      Enum.map_join(@layout_keys, "\n", fn {layout, keys} ->
        required = @layout_required[layout]

        parts =
          [
            required != [] && "required: #{Enum.join(required, ", ")}",
            keys != required && "optional: #{Enum.join(keys -- required, ", ")}"
          ]
          |> Enum.filter(&is_binary/1)
          |> Enum.join("; ")

        "- \"#{layout}\": #{parts}"
      end)

    """
    A deck is a JSON object: {"title", "accent", "theme"?, "voice"?, "slides": [...]}.
    Each slide is a JSON object with a required "layout" plus keys for that layout.

    Layouts (with their required and optional keys):
    #{layouts}

    Keys allowed on EVERY slide: #{Enum.join(@common_keys, ", ")}.
    Any other key is rejected by the validator.
    Required string fields must be NON-EMPTY. Slide ids must be unique.

    IMAGES ON SLIDES: NEVER include an "image" key — existing images are
    managed by the app and preserved automatically. If (and only if) the
    request asks for a new or different image, include
    "image_request": {"subject": "<one sentence describing the image>"}
    at the top level of the slide object — the app generates and attaches it.

    Limits (the validator rejects anything larger):
    - at most #{@max_slides} slides per deck
    - at most #{@max_list_items} items in any list (columns, points, steps, rows, items)
    - at most #{@max_string_bytes} characters in any single text field

    Enums (the ONLY allowed values):
    - accent: #{Enum.join(@accents, ", ")}
    - theme: #{Enum.join(@themes, ", ")}
    - tone: #{Enum.join(@tones, ", ")}
    - size: #{Enum.join(@sizes, ", ")}
    - flow step color: #{Enum.join(@flow_colors, ", ")}
    - table cell tint: #{Enum.join(@tints, ", ")}
    - media kind: #{Enum.join(@media_kinds, ", ")}

    Shapes:
    - "columns" (bullets): list of 1-2 lists of strings.
    - "points": list of {"label", "body"}.
    - "steps" (flow): list of {"actor", "body", "color"?, "arrow_label"?}.
    - "rows" (table): list of rows; each row has exactly as many cells as "columns";
      a cell is a string or {"text", "tint"}.
    - "items" (faq): list of {"q", "a"}.
    Items in "points"/"steps"/"items" carry an app-assigned "id" — when
    returning a whole slide, preserve each item's "id" exactly; never invent
    ids for new items (omit "id" and the app assigns one).

    IMAGES: You cannot generate or find images, and you must NEVER invent an
    image file path or URL. For a media slide, set "kind" and put a short
    description of the wanted image in "caption", and OMIT "src" entirely — a
    placeholder renders and the user adds the real image later. Only ever
    include "src" if the user gave you an exact existing local path or https
    URL. Prefer non-media layouts unless an image genuinely adds something.

    Text fields support ONLY this inline markup: **strong**, ==accent==,
    ~~strike~~, `code`, and literal newlines. NO HTML anywhere, ever.
    """
  end

  # ----- Storage --------------------------------------------------------------
  #
  # One Postgres row per deck (Decks.Stored), keyed by a URL-safe id, owned by
  # a user. Presenting is public-by-link; only the owner may edit. Swapping
  # the store (e.g. Neon) touches nothing outside this section.

  alias Uitstalling.Decks.{Request, Stored}
  alias Uitstalling.Repo

  import Ecto.Query

  @doc "The parsed deck with the given id."
  def deck!(deck_id) do
    {:ok, deck} = parse(load_raw!(deck_id))
    deck
  end

  @doc "Whether a deck with this id exists."
  def exists?(deck_id), do: Repo.exists?(from(d in Stored, where: d.id == ^deck_id))

  @doc "The user id that owns a deck, or nil."
  def owner_id(deck_id) do
    Repo.one(from(d in Stored, where: d.id == ^deck_id, select: d.user_id))
  end

  @doc "Whether `user_id` owns the deck (nil user never owns)."
  def owned_by?(_deck_id, nil), do: false
  def owned_by?(deck_id, user_id), do: owner_id(deck_id) == user_id

  @doc """
  A user's decks as `{id, %Deck{}}`, newest first. A stored deck that no
  longer validates is surfaced as a degraded placeholder instead of silently
  vanishing from the list.
  """
  def list(user_id) do
    Repo.all(from(d in Stored, where: d.user_id == ^user_id, order_by: [desc: d.updated_at]))
    |> Enum.map(fn row ->
      raw = migrate(row.data)

      case parse(raw) do
        {:ok, deck} ->
          {row.id, deck}

        {:error, _} ->
          title = if is_binary(raw["title"]), do: raw["title"], else: "Untitled"
          {row.id, %Deck{title: "#{title} (needs repair)", slides: []}}
      end
    end)
  end

  @doc "A deck's raw JSON map — the form mutations operate on. Always migrated."
  def load_raw!(deck_id) do
    Repo.get!(Stored, deck_id).data |> migrate()
  end

  @doc """
  Upgrade a stored raw deck map to the current document version. Pure and
  idempotent; applied on every load and before every save, so documents
  written under older rules converge instead of failing a tightened validator.
  Current migrations: stamp "v", backfill missing/duplicate slide ids ("sN")
  and part ids ("pN") on the id-addressable part lists.
  """
  def migrate(%{} = raw) do
    raw
    |> Map.put("v", @doc_version)
    |> Map.update("slides", [], fn
      slides when is_list(slides) ->
        slides |> ensure_ids("s") |> Enum.map(&backfill_part_ids/1)

      other ->
        other
    end)
  end

  # Each layout has at most one part list, so per-list uniqueness is
  # per-slide uniqueness.
  defp backfill_part_ids(%{} = slide) do
    Enum.reduce(Op.part_lists(), slide, fn key, acc ->
      case acc[key] do
        list when is_list(list) -> Map.put(acc, key, ensure_ids(list, "p"))
        _ -> acc
      end
    end)
  end

  defp backfill_part_ids(other), do: other

  # Give every map item a unique string id, preserving existing unique ones.
  # Positional fallbacks skip past taken ids so a mint never collides.
  defp ensure_ids(items, prefix) when is_list(items) do
    taken =
      for %{} = item <- items,
          is_binary(item["id"]) and item["id"] != "",
          into: MapSet.new(),
          do: item["id"]

    {items, _seen} =
      items
      |> Enum.with_index()
      |> Enum.map_reduce(MapSet.new(), fn {item, i}, seen ->
        case item do
          %{"id" => id} when is_binary(id) and id != "" ->
            if MapSet.member?(seen, id),
              do:
                {Map.put(item, "id", mint_id(prefix, i, MapSet.union(taken, seen))),
                 MapSet.put(seen, id)},
              else: {item, MapSet.put(seen, id)}

          %{} ->
            id = mint_id(prefix, i, MapSet.union(taken, seen))
            {Map.put(item, "id", id), MapSet.put(seen, id)}

          other ->
            {other, seen}
        end
      end)

    items
  end

  defp mint_id(prefix, i, taken) do
    id = "#{prefix}#{i}"
    if MapSet.member?(taken, id), do: mint_id(prefix, i + 1, taken), else: id
  end

  @doc "Create a new deck owned by `user_id`. Refuses invalid decks."
  def create_deck!(user_id, deck_id, %{} = raw) do
    raw = migrate(raw)
    {:ok, _deck} = parse(raw)

    Repo.insert!(%Stored{id: deck_id, user_id: user_id, data: raw})
    raw
  end

  @doc "Persist changes to an existing deck. Refuses anything that doesn't validate."
  def save!(deck_id, %{} = raw) do
    raw = migrate(raw)
    {:ok, _deck} = parse(raw)

    {1, _} =
      Repo.update_all(
        from(d in Stored, where: d.id == ^deck_id),
        set: [data: raw, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    raw
  end

  @doc "Delete a deck and its queued requests."
  def delete_deck(deck_id) do
    Repo.delete_all(from(r in Request, where: r.deck_id == ^deck_id))
    Repo.delete_all(from(d in Stored, where: d.id == ^deck_id))
    :ok
  end

  @doc "Generate a fresh URL-safe deck id."
  def generate_id do
    Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
  end

  # ----- Public slugs -----------------------------------------------------------
  #
  # /:user_slug/:deck_slug — the deck slug is minted from the title once the
  # REAL title exists (after generation, not from the "New presentation"
  # stub) and then never changes: it's in people's shared links. The raw
  # deck id is always accepted where a slug is, so pre-slug links survive.

  @doc "Set the deck's slug from its current title, if it doesn't have one yet."
  def ensure_deck_slug(deck_id) do
    case Repo.get(Stored, deck_id) do
      %Stored{slug: nil, user_id: user_id} = stored ->
        title = stored.data["title"] || "deck"

        slug =
          Uitstalling.Slug.unique(title, deck_id, fn candidate ->
            Repo.exists?(from(d in Stored, where: d.user_id == ^user_id and d.slug == ^candidate))
          end)

        stored |> Ecto.Changeset.change(slug: slug) |> Repo.update!()
        slug

      %Stored{slug: slug} ->
        slug

      nil ->
        nil
    end
  end

  @doc "The deck id living at /:user_slug/:deck_slug — matches slug OR raw id."
  def deck_id_for(user_id, slug_or_id) when is_binary(slug_or_id) do
    Repo.one(
      from(d in Stored,
        where: d.user_id == ^user_id and (d.slug == ^slug_or_id or d.id == ^slug_or_id),
        select: d.id
      )
    )
  end

  def deck_id_for(_user_id, _slug_or_id), do: nil

  @doc "The deck's public slug (or its id while no slug is set yet)."
  def deck_slug(deck_id) do
    Repo.one(from(d in Stored, where: d.id == ^deck_id, select: d.slug)) || deck_id
  end

  # ----- Mutations ------------------------------------------------------------
  #
  # Pure functions from raw map -> raw map. Callers re-run `parse/1` on the
  # result: an edit that breaks the schema (deleting a required part, the last
  # item of a list, the last slide) is rejected by the same validator that
  # polices the model — no special-casing needed.

  @doc "Set a common key (e.g. \"size\") on the slide at `index`."
  def put_slide_key(raw, index, key, value) when key in @common_keys do
    update_in(raw, ["slides", Access.at(index)], &Map.put(&1, key, value))
  end

  @doc """
  Delete the block at `path` on the slide at `index`. A path is a scalar key
  (`"subheading"`), a list element (`"points.1"`), or a field inside a
  map-shaped list element (`"steps.2.body"`). Unparseable paths are a no-op.
  """
  def delete_block(raw, index, path) do
    update_in(raw, ["slides", Access.at(index)], fn slide ->
      case BlockPath.parse(path) do
        {:ok, {:key, key}} ->
          Map.delete(slide, key)

        {:ok, {:item, key, pos}} ->
          case slide[key] do
            list when is_list(list) -> Map.put(slide, key, List.delete_at(list, pos))
            _ -> slide
          end

        {:ok, {:field, key, pos, sub}} ->
          update_list_item(slide, key, pos, &Map.delete(&1, sub))

        :error ->
          slide
      end
    end)
  end

  @doc "Delete the slide at `index`."
  def delete_slide(raw, index) do
    Map.update!(raw, "slides", &List.delete_at(&1, index))
  end

  @doc """
  Insert a placeholder slide after `index` — the direct "grow the deck"
  path, no model involved (the counterpart of `delete_slide/2`). The
  placeholder validates on its own; the author types it exactly or hands
  it to the agent from the editor it lands in.
  """
  def insert_slide(raw, index) do
    slides = raw["slides"]
    taken = for %{"id" => id} <- slides, is_binary(id), into: MapSet.new(), do: id

    id =
      Stream.iterate(length(slides), &(&1 + 1))
      |> Stream.map(&"s#{&1}")
      |> Enum.find(&(not MapSet.member?(taken, &1)))

    slide = %{
      "id" => id,
      "layout" => "statement",
      "body" => "A new point to make…"
    }

    Map.put(raw, "slides", List.insert_at(slides, index + 1, slide))
  end

  @doc "Fetch the value at a block path (`\"heading\"`, `\"points.1\"`, `\"steps.2.body\"`)."
  def get_block(raw, index, path) do
    slide = Enum.at(raw["slides"], index) || %{}

    case BlockPath.parse(path) do
      {:ok, {:key, key}} ->
        slide[key]

      {:ok, {:item, key, pos}} ->
        Enum.at(slide[key] || [], pos)

      {:ok, {:field, key, pos, sub}} ->
        case Enum.at(slide[key] || [], pos) do
          %{} = item -> item[sub]
          _ -> nil
        end

      :error ->
        nil
    end
  end

  @doc "Replace the value at a block path. Callers validate via `parse/1`."
  def put_block(raw, index, path, value) do
    update_in(raw, ["slides", Access.at(index)], fn slide ->
      case BlockPath.parse(path) do
        {:ok, {:key, key}} ->
          Map.put(slide, key, value)

        {:ok, {:item, key, pos}} ->
          case slide[key] do
            list when is_list(list) -> Map.put(slide, key, List.replace_at(list, pos, value))
            _ -> slide
          end

        {:ok, {:field, key, pos, sub}} ->
          update_list_item(slide, key, pos, &Map.put(&1, sub, value))

        :error ->
          slide
      end
    end)
  end

  # Apply `fun` to the map-shaped item at `pos` in the list at `key`;
  # anything that isn't a map in a list leaves the slide unchanged.
  defp update_list_item(slide, key, pos, fun) do
    case slide[key] do
      list when is_list(list) ->
        case Enum.at(list, pos) do
          %{} = item -> Map.put(slide, key, List.replace_at(list, pos, fun.(item)))
          _ -> slide
        end

      _ ->
        slide
    end
  end

  @doc "Append `item` to the list at `key` on the slide at `index`."
  def append_item(raw, index, key, item) do
    update_in(raw, ["slides", Access.at(index)], fn slide ->
      Map.update(slide, key, [item], &(&1 ++ [item]))
    end)
  end

  # ----- Edit-request queue -----------------------------------------------------
  #
  # Structured queue the agent works through: each request carries a stable
  # slide id, optional block path, and a status the UI renders as a
  # "generating…" overlay. Stand-in for the real pipeline's DB table.

  @doc "All requests, oldest first, as flat maps."
  def load_requests do
    Repo.all(from(r in Request, order_by: [asc: r.id]))
    |> Enum.map(&request_map/1)
  end

  @doc "All requests waiting to be picked up, oldest first."
  def pending_requests do
    Repo.all(from(r in Request, where: r.status == "pending", order_by: [asc: r.id]))
    |> Enum.map(&request_map/1)
  end

  @doc "One deck's requests waiting to be picked up, oldest first — a DeckWorker's inbox."
  def pending_deck_requests(deck_id) do
    Repo.all(
      from(r in Request,
        where: r.status == "pending" and r.deck_id == ^deck_id,
        order_by: [asc: r.id]
      )
    )
    |> Enum.map(&request_map/1)
  end

  @doc "Deck ids with unfinished (pending or in-flight) requests — kicked on boot."
  def unfinished_deck_ids do
    Repo.all(
      from(r in Request,
        where: r.status in ["pending", "processing"],
        distinct: true,
        select: r.deck_id
      )
    )
  end

  @doc "Requests not yet finished (pending or in flight) — what the UI shows as generating."
  def open_requests do
    Repo.all(
      from(r in Request, where: r.status in ["pending", "processing"], order_by: [asc: r.id])
    )
    |> Enum.map(&request_map/1)
  end

  @doc """
  Append a pending request. Returns the stored request as a flat map.
  Raises on a structurally-bad payload — the UI sanitizes its inputs, so this
  guards future non-UI callers, not user input.
  """
  def queue_request(%{} = attrs) do
    type = attrs["type"] || "edit"

    cond do
      type not in ~w(edit create asset) ->
        raise ArgumentError, "unknown request type #{inspect(type)}"

      not exists?(attrs["deck_id"]) ->
        raise ArgumentError, "deck #{inspect(attrs["deck_id"])} does not exist"

      not (is_binary(attrs["prompt"]) and String.trim(attrs["prompt"]) != "") ->
        raise ArgumentError, "request needs a non-empty prompt"

      type == "create" and (attrs["theme"] not in @themes or attrs["accent"] not in @accents) ->
        raise ArgumentError, "create request needs a valid theme and accent"

      type in ~w(edit asset) and not is_binary(attrs["slide_id"]) ->
        raise ArgumentError, "#{type} request needs a slide_id"

      true ->
        Repo.insert!(%Request{
          deck_id: attrs["deck_id"],
          type: type,
          status: "pending",
          payload: attrs
        })
        |> request_map()
    end
  end

  @doc "Mark a request as picked up by the pipeline."
  def mark_processing(id) do
    Repo.update_all(from(r in Request, where: r.id == ^id), set: [status: "processing"])
    :ok
  end

  @doc """
  Fail one deck's requests stuck in "processing" — those belong to a worker
  run that crashed mid-flight. Each DeckWorker sweeps only its own deck on
  boot, so a request that crashes a worker is delivered at most twice and a
  restarting worker can't touch another deck's in-flight request.
  """
  def fail_stale_processing(deck_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(r in Request, where: r.status == "processing" and r.deck_id == ^deck_id),
      set: [status: "failed", error: "interrupted by restart", done_at: now]
    )

    :ok
  end

  @doc """
  Set status/error/done_at on the request with `id`. A canceled request is
  final — a worker finishing after the user hit cancel must not resurrect it,
  so this is a no-op on canceled rows.
  """
  def update_request(id, %{} = attrs) do
    done_at =
      case attrs["done_at"] do
        nil -> DateTime.utc_now() |> DateTime.truncate(:second)
        iso -> iso |> DateTime.from_iso8601() |> elem(1) |> DateTime.truncate(:second)
      end

    Repo.update_all(
      from(r in Request, where: r.id == ^id and r.status != "canceled"),
      set: [status: attrs["status"], error: attrs["error"], done_at: done_at]
    )

    :ok
  end

  @doc """
  Cancel a request (pending or in flight). The status flip is what the
  workers observe: drains skip it, a finishing worker's update no-ops, and
  the pipelines check `canceled?/1` before persisting results. Killing an
  in-flight generation task is the AssetPipeline's job — callers nudge it
  separately.
  """
  def cancel_request(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(r in Request, where: r.id == ^id and r.status in ["pending", "processing"]),
      set: [status: "canceled", error: nil, done_at: now]
    )

    :ok
  end

  @doc "Whether the request was canceled (workers check before persisting)."
  def canceled?(id) do
    Repo.exists?(from(r in Request, where: r.id == ^id and r.status == "canceled"))
  end

  @doc """
  The most recent "create" request for a deck (any status), as a flat map —
  the editor's regenerate flow prefills from its prompt/research. Nil for
  decks that predate the request log.
  """
  def latest_create_request(deck_id) do
    Repo.one(
      from(r in Request,
        where: r.deck_id == ^deck_id and r.type == "create",
        order_by: [desc: r.id],
        limit: 1
      )
    )
    |> case do
      nil -> nil
      request -> request_map(request)
    end
  end

  @doc "Failed requests for a deck finished at or after `since`, newest first."
  def recent_failed_requests(deck_id, since) do
    Repo.all(
      from(r in Request,
        where: r.deck_id == ^deck_id and r.status == "failed" and r.done_at >= ^since,
        order_by: [desc: r.done_at]
      )
    )
    |> Enum.map(&request_map/1)
  end

  # The pipeline/agent consume a flat map; managed columns override payload.
  defp request_map(%Request{} = r) do
    Map.merge(r.payload, %{
      "id" => r.id,
      "deck_id" => r.deck_id,
      "type" => r.type,
      "status" => r.status,
      "error" => r.error
    })
  end

  # ----- Validation ---------------------------------------------------------

  defp validate(map) do
    req_string(map, "title", "deck") ++
      enum(map, "accent", @accents, "deck") ++
      opt_string(map, "voice", "deck") ++
      enum(map, "theme", @themes, "deck") ++
      case map["slides"] do
        [_ | _] = slides when length(slides) <= @max_slides ->
          slides
          |> Enum.with_index()
          |> Enum.flat_map(fn {slide, i} -> validate_slide(slide, i) end)
          |> Kernel.++(duplicate_id_errors(slides))

        [_ | _] ->
          ["deck.slides: must have at most #{@max_slides} slides"]

        _ ->
          ["deck.slides: must be a non-empty list"]
      end
  end

  # Part ids address ops — like slide ids, a duplicate (or non-string) id
  # would let an op land on the wrong part.
  defp part_id_errors(s, path) do
    ids =
      for key <- Op.part_lists(),
          list = s[key],
          is_list(list),
          %{} = item <- list,
          Map.has_key?(item, "id"),
          do: item["id"]

    {strings, junk} = Enum.split_with(ids, &(is_binary(&1) and &1 != ""))

    junk_errors =
      if junk == [], do: [], else: ["#{path}: part ids must be non-empty strings"]

    dup_errors =
      case Enum.uniq(strings -- Enum.uniq(strings)) do
        [] -> []
        dups -> ["#{path}: duplicate part ids #{inspect(dups)} — every part id must be unique"]
      end

    junk_errors ++ dup_errors
  end

  # Slide ids address edits — a duplicate would let one edit land on the
  # wrong slide, so it is rejected like any other schema violation.
  defp duplicate_id_errors(slides) do
    ids = for %{} = s <- slides, is_binary(s["id"]), do: s["id"]

    case Enum.uniq(ids -- Enum.uniq(ids)) do
      [] -> []
      dups -> ["deck.slides: duplicate slide ids #{inspect(dups)} — every id must be unique"]
    end
  end

  defp validate_slide(%{} = s, i) do
    path = "slides[#{i}]"

    case s["layout"] do
      layout when layout in @layouts ->
        unknown = Map.keys(s) -- (@common_keys ++ @app_keys ++ @layout_keys[layout])

        unknown_errors =
          if unknown == [],
            do: [],
            else: ["#{path}: unknown keys #{inspect(unknown)} for layout \"#{layout}\""]

        unknown_errors ++
          enum(s, "tone", @tones, path) ++
          enum(s, "size", @sizes, path) ++
          opt_string(s, "id", path) ++
          opt_string(s, "kicker", path) ++
          opt_string(s, "footnote", path) ++
          opt_string(s, "notes", path) ++
          validate_image(s["image"], path) ++
          part_id_errors(s, path) ++
          validate_fields(layout, s, path)

      other ->
        ["#{path}.layout: #{inspect(other)} must be one of: #{Enum.join(@layouts, ", ")}"]
    end
  end

  defp validate_slide(_s, i), do: ["slides[#{i}]: must be an object"]

  # The image part references a stored asset by id. Only the shape is checked
  # here — existence is a UI/render concern (a deleted asset degrades to a
  # placeholder), which keeps parse/1 free of DB access. The id format check
  # still rejects anything a model could invent by pattern.
  defp validate_image(nil, _path), do: []

  defp validate_image(%{} = image, path) do
    id_errors =
      case image["asset_id"] do
        id when is_binary(id) ->
          if id =~ ~r/^ast_[a-f0-9]{16}$/,
            do: [],
            else: ["#{path}.image.asset_id: not a valid asset id"]

        _ ->
          ["#{path}.image.asset_id: required string"]
      end

    unknown = Map.keys(image) -- ~w(asset_id alt treatment crop)

    unknown_errors =
      if unknown == [], do: [], else: ["#{path}.image: unknown keys #{inspect(unknown)}"]

    id_errors ++
      unknown_errors ++
      opt_string(image, "alt", "#{path}.image") ++
      enum(image, "treatment", @image_treatments, "#{path}.image") ++
      validate_crop(image["crop"], path)
  end

  defp validate_image(_other, path),
    do: ["#{path}.image: must be an object with \"asset_id\""]

  # A crop is three bounded numbers — pan focal point (percent) + zoom. The
  # renderer builds CSS from these itself; JSON never carries styling.
  defp validate_crop(nil, _path), do: []

  defp validate_crop(%{} = crop, path) do
    unknown = Map.keys(crop) -- ~w(x y zoom)

    checks = [
      {crop["x"], "x", 0, 100},
      {crop["y"], "y", 0, 100},
      {crop["zoom"], "zoom", 1, 4}
    ]

    range_errors =
      for {value, key, min, max} <- checks,
          not (is_number(value) and value >= min and value <= max) do
        "#{path}.image.crop.#{key}: must be a number between #{min} and #{max}"
      end

    if unknown == [],
      do: range_errors,
      else: ["#{path}.image.crop: unknown keys #{inspect(unknown)}" | range_errors]
  end

  defp validate_crop(_other, path),
    do: ["#{path}.image.crop: must be an object with x, y, zoom"]

  defp validate_fields("title", s, p),
    do: req_string(s, "heading", p) ++ opt_string(s, "subheading", p)

  defp validate_fields("statement", s, p),
    do: opt_string(s, "heading", p) ++ req_string(s, "body", p)

  defp validate_fields("bullets", s, p) do
    req_string(s, "heading", p) ++
      case s["columns"] do
        [_ | _] = cols when length(cols) <= 2 ->
          cols
          |> Enum.with_index()
          |> Enum.flat_map(fn {col, ci} ->
            cond do
              not (is_list(col) and col != [] and Enum.all?(col, &is_binary/1)) ->
                ["#{p}.columns[#{ci}]: must be a non-empty list of strings"]

              length(col) > @max_list_items ->
                ["#{p}.columns[#{ci}]: must have at most #{@max_list_items} bullets"]

              true ->
                col
                |> Enum.with_index()
                |> Enum.flat_map(fn {s, bi} ->
                  check_text(s, "bullet", "#{p}.columns[#{ci}][#{bi}]")
                end)
            end
          end)

        _ ->
          ["#{p}.columns: must be a list of 1 or 2 columns"]
      end
  end

  defp validate_fields("points", s, p) do
    req_string(s, "heading", p) ++
      list_of_objects(s, "points", p, fn point, pp ->
        req_string(point, "label", pp) ++ req_string(point, "body", pp)
      end)
  end

  defp validate_fields("flow", s, p) do
    opt_string(s, "heading", p) ++
      opt_string(s, "terminal", p) ++
      list_of_objects(s, "steps", p, fn step, sp ->
        req_string(step, "actor", sp) ++
          req_string(step, "body", sp) ++
          enum(step, "color", @flow_colors, sp) ++
          opt_string(step, "arrow_label", sp)
      end)
  end

  defp validate_fields("big_code", s, p),
    do: opt_string(s, "heading", p) ++ req_string(s, "code", p) ++ opt_string(s, "body", p)

  defp validate_fields("table", s, p) do
    opt_string(s, "heading", p) ++
      case {s["columns"], s["rows"]} do
        {[_ | _] = cols, [_ | _] = rows} ->
          col_errors =
            if Enum.all?(cols, &is_binary/1),
              do: [],
              else: ["#{p}.columns: must be a list of strings"]

          row_errors =
            rows
            |> Enum.with_index()
            |> Enum.flat_map(fn {row, ri} ->
              validate_row(row, length(cols), "#{p}.rows[#{ri}]")
            end)

          col_errors ++ row_errors

        _ ->
          ["#{p}: table needs non-empty \"columns\" and \"rows\" lists"]
      end
  end

  defp validate_fields("media", s, p) do
    # src is optional — a media slide with no src renders a placeholder from
    # its caption. This is deliberate: the text agent cannot make or find
    # images, so it must omit src (and describe the wanted image in caption)
    # rather than invent a path. Real images arrive via a separate pipeline.
    enum_req(s, "kind", @media_kinds, p) ++
      opt_string(s, "src", p) ++
      safe_src(s["src"], p) ++
      opt_string(s, "heading", p) ++
      opt_string(s, "caption", p)
  end

  defp validate_fields("faq", s, p) do
    opt_string(s, "heading", p) ++
      list_of_objects(s, "items", p, fn item, ip ->
        req_string(item, "q", ip) ++ req_string(item, "a", ip)
      end)
  end

  defp validate_row(row, width, path) when is_list(row) do
    length_errors =
      if length(row) == width,
        do: [],
        else: ["#{path}: has #{length(row)} cells but the table has #{width} columns"]

    cell_errors =
      row
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {cell, ci} when is_binary(cell) ->
          check_text(cell, "cell", "#{path}[#{ci}]")

        {%{"text" => t} = cell, ci} when is_binary(t) ->
          enum(cell, "tint", @tints, "#{path}[#{ci}]") ++ check_text(t, "cell", "#{path}[#{ci}]")

        {_other, ci} ->
          ["#{path}[#{ci}]: must be a string or {\"text\": \"...\", \"tint\": \"ok|warn|bad\"}"]
      end)

    length_errors ++ cell_errors
  end

  defp validate_row(_row, _width, path), do: ["#{path}: must be a list of cells"]

  # A local src must resolve to a real file under priv/static; https is taken
  # on trust. This closes the hallucinated-path hole: the text agent inventing
  # "/images/ear-care.jpg" is rejected (the file doesn't exist), forcing it to
  # omit src per the prompt. The "//" check matters: a protocol-relative
  # "//evil.example/x.png" would otherwise pass as "local".
  defp safe_src(src, path) when is_binary(src) do
    cond do
      String.starts_with?(src, "https://") ->
        []

      String.starts_with?(src, "/") and not String.starts_with?(src, "//") ->
        if local_asset_exists?(src),
          do: [],
          else: [
            "#{path}.src: local image \"#{src}\" does not exist (omit src to show a placeholder)"
          ]

      true ->
        ["#{path}.src: must be a local path (\"/...\") or an https:// URL"]
    end
  end

  defp safe_src(_src, _path), do: []

  defp local_asset_exists?(src) do
    rel = src |> String.trim_leading("/") |> String.split(~r/[?#]/) |> hd()

    # Path.expand collapses any ".." — a path that escapes the static root
    # after expansion is rejected outright, so validation can't be used to
    # probe (or accept) files outside priv/static.
    Enum.any?(static_roots(), fn root ->
      full = Path.expand(rel, root)
      String.starts_with?(full, root <> "/") and File.exists?(full)
    end)
  end

  defp static_roots do
    # The built app dir, plus the source tree so newly-added dev assets
    # validate before a build.
    [Application.app_dir(:uitstalling, "priv/static"), Path.expand("priv/static")]
  end

  # ----- Validation helpers -------------------------------------------------

  defp req_string(map, key, path) do
    case map[key] do
      s when is_binary(s) and s != "" -> check_text(s, key, "#{path}.#{key}")
      _ -> ["#{path}.#{key}: required non-empty string"]
    end
  end

  defp opt_string(map, key, path) do
    case map[key] do
      nil -> []
      s when is_binary(s) -> check_text(s, key, "#{path}.#{key}")
      _ -> ["#{path}.#{key}: must be a string"]
    end
  end

  # Content rules for any accepted string: bounded size, and the NO-HTML rule
  # the prompt states. "code" is exempt from the tag check — code samples
  # legitimately contain markup (everything is escaped at render regardless).
  defp check_text(s, key, path) do
    size_errors =
      if byte_size(s) <= @max_string_bytes,
        do: [],
        else: ["#{path}: must be at most #{@max_string_bytes} characters"]

    html_errors =
      if key != "code" and s =~ ~r{</?[a-zA-Z][a-zA-Z0-9-]*(\s[^>]*)?>},
        do: [
          "#{path}: HTML tags are not allowed — use **strong**, ==accent==, ~~strike~~, `code`"
        ],
        else: []

    size_errors ++ html_errors
  end

  defp enum(map, key, allowed, path) do
    case map[key] do
      nil ->
        []

      v ->
        if is_binary(v) and v in allowed,
          do: [],
          else: ["#{path}.#{key}: #{inspect(v)} must be one of: #{Enum.join(allowed, ", ")}"]
    end
  end

  defp enum_req(map, key, allowed, path) do
    case map[key] do
      nil -> ["#{path}.#{key}: required, one of: #{Enum.join(allowed, ", ")}"]
      _ -> enum(map, key, allowed, path)
    end
  end

  defp list_of_objects(map, key, path, fun) do
    case map[key] do
      [_ | _] = items when length(items) <= @max_list_items ->
        items
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {%{} = item, i} -> fun.(item, "#{path}.#{key}[#{i}]")
          {_other, i} -> ["#{path}.#{key}[#{i}]: must be an object"]
        end)

      [_ | _] ->
        ["#{path}.#{key}: must have at most #{@max_list_items} items"]

      _ ->
        ["#{path}.#{key}: required non-empty list"]
    end
  end

  # ----- Building -----------------------------------------------------------

  defp build(map) do
    %Deck{
      title: map["title"],
      accent: map["accent"] || "amber",
      theme: map["theme"] || "noir",
      voice: map["voice"],
      slides:
        map["slides"]
        |> Enum.with_index()
        |> Enum.map(fn {s, i} ->
          %Slide{
            id: s["id"] || "s#{i}",
            layout: s["layout"],
            tone: s["tone"] || "default",
            size: s["size"] || "md",
            kicker: s["kicker"],
            footnote: s["footnote"],
            notes: s["notes"],
            fields: Map.drop(s, @common_keys)
          }
        end)
    }
  end
end
