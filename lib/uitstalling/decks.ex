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

  alias Uitstalling.Decks.{Deck, Slide}

  @accents ~w(amber sky emerald rose violet cyan)
  @tones ~w(default accent danger light)
  @flow_colors ~w(zinc sky emerald amber rose)
  @tints ~w(none ok warn bad)
  @media_kinds ~w(image video)

  @sizes ~w(sm md lg)
  @themes ~w(noir midnight)

  # Keys every slide may carry, regardless of layout.
  @common_keys ~w(id layout tone size kicker footnote notes)

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

  def accents, do: @accents
  def tones, do: @tones
  def flow_colors, do: @flow_colors
  def layouts, do: @layouts
  def themes, do: @themes

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
  The design system described for the generation model, derived from the same
  module attributes the validator enforces — one source of truth for schema,
  validator, and prompt.
  """
  def schema_prompt do
    layouts =
      Enum.map_join(@layout_keys, "\n", fn {layout, keys} ->
        "- \"#{layout}\": layout-specific keys: #{Enum.join(keys, ", ")}"
      end)

    """
    A deck is a JSON object: {"title", "accent", "theme"?, "voice"?, "slides": [...]}.
    Each slide is a JSON object with a required "layout" plus keys for that layout.

    Layouts:
    #{layouts}

    Keys allowed on EVERY slide: #{Enum.join(@common_keys, ", ")}.
    Any other key is rejected by the validator.

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
  def exists?(deck_id), do: Repo.exists?(from d in Stored, where: d.id == ^deck_id)

  @doc "The user id that owns a deck, or nil."
  def owner_id(deck_id) do
    Repo.one(from d in Stored, where: d.id == ^deck_id, select: d.user_id)
  end

  @doc "Whether `user_id` owns the deck (nil user never owns)."
  def owned_by?(_deck_id, nil), do: false
  def owned_by?(deck_id, user_id), do: owner_id(deck_id) == user_id

  @doc "A user's decks as `{id, %Deck{}}`, newest first."
  def list(user_id) do
    Repo.all(from d in Stored, where: d.user_id == ^user_id, order_by: [desc: d.updated_at])
    |> Enum.flat_map(fn row ->
      case parse(row.data) do
        {:ok, deck} -> [{row.id, deck}]
        {:error, _} -> []
      end
    end)
  end

  @doc "A deck's raw JSON map — the form mutations operate on."
  def load_raw!(deck_id) do
    Repo.get!(Stored, deck_id).data
  end

  @doc "Create a new deck owned by `user_id`. Refuses invalid decks."
  def create_deck!(user_id, deck_id, %{} = raw) do
    {:ok, _deck} = parse(raw)

    Repo.insert!(%Stored{id: deck_id, user_id: user_id, data: raw})
    raw
  end

  @doc "Persist changes to an existing deck. Refuses anything that doesn't validate."
  def save!(deck_id, %{} = raw) do
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
    Repo.delete_all(from r in Request, where: r.deck_id == ^deck_id)
    Repo.delete_all(from d in Stored, where: d.id == ^deck_id)
    :ok
  end

  @doc "Generate a fresh URL-safe deck id."
  def generate_id do
    Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
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
  Delete the block at `path` on the slide at `index`. A path is either a
  scalar key (`"subheading"`) or a list element (`"points.1"`).
  """
  def delete_block(raw, index, path) do
    update_in(raw, ["slides", Access.at(index)], fn slide ->
      case String.split(path, ".") do
        [key] ->
          Map.delete(slide, key)

        [key, pos] ->
          case {slide[key], Integer.parse(pos)} do
            {list, {pos, ""}} when is_list(list) -> Map.put(slide, key, List.delete_at(list, pos))
            _ -> slide
          end

        _ ->
          slide
      end
    end)
  end

  @doc "Delete the slide at `index`."
  def delete_slide(raw, index) do
    Map.update!(raw, "slides", &List.delete_at(&1, index))
  end

  @doc "Fetch the value at a block path (`\"heading\"`, `\"points.1\"`)."
  def get_block(raw, index, path) do
    slide = Enum.at(raw["slides"], index) || %{}

    case String.split(path, ".") do
      [key] ->
        slide[key]

      [key, pos] ->
        case Integer.parse(pos) do
          {i, ""} -> Enum.at(slide[key] || [], i)
          _ -> nil
        end
    end
  end

  @doc "Replace the value at a block path. Callers validate via `parse/1`."
  def put_block(raw, index, path, value) do
    update_in(raw, ["slides", Access.at(index)], fn slide ->
      case String.split(path, ".") do
        [key] ->
          Map.put(slide, key, value)

        [key, pos] ->
          case {slide[key], Integer.parse(pos)} do
            {list, {i, ""}} when is_list(list) ->
              Map.put(slide, key, List.replace_at(list, i, value))

            _ ->
              slide
          end
      end
    end)
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
    Repo.all(from r in Request, order_by: [asc: r.id])
    |> Enum.map(&request_map/1)
  end

  @doc "Requests still waiting on the agent, oldest first."
  def pending_requests do
    Repo.all(from r in Request, where: r.status == "pending", order_by: [asc: r.id])
    |> Enum.map(&request_map/1)
  end

  @doc "Append a pending request. Returns the stored request as a flat map."
  def queue_request(%{} = attrs) do
    Repo.insert!(%Request{
      deck_id: attrs["deck_id"],
      type: attrs["type"] || "edit",
      status: "pending",
      payload: attrs
    })
    |> request_map()
  end

  @doc "Set status/error/done_at on the request with `id`."
  def update_request(id, %{} = attrs) do
    done_at =
      case attrs["done_at"] do
        nil -> DateTime.utc_now() |> DateTime.truncate(:second)
        iso -> iso |> DateTime.from_iso8601() |> elem(1) |> DateTime.truncate(:second)
      end

    Repo.update_all(
      from(r in Request, where: r.id == ^id),
      set: [status: attrs["status"], error: attrs["error"], done_at: done_at]
    )

    :ok
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
        [_ | _] = slides ->
          slides
          |> Enum.with_index()
          |> Enum.flat_map(fn {slide, i} -> validate_slide(slide, i) end)

        _ ->
          ["deck.slides: must be a non-empty list"]
      end
  end

  defp validate_slide(%{} = s, i) do
    path = "slides[#{i}]"

    case s["layout"] do
      layout when layout in @layouts ->
        unknown = Map.keys(s) -- (@common_keys ++ @layout_keys[layout])

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
          validate_fields(layout, s, path)

      other ->
        ["#{path}.layout: #{inspect(other)} must be one of: #{Enum.join(@layouts, ", ")}"]
    end
  end

  defp validate_slide(_s, i), do: ["slides[#{i}]: must be an object"]

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
            if is_list(col) and col != [] and Enum.all?(col, &is_binary/1),
              do: [],
              else: ["#{p}.columns[#{ci}]: must be a non-empty list of strings"]
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
        {cell, _ci} when is_binary(cell) ->
          []

        {%{"text" => t} = cell, ci} when is_binary(t) ->
          enum(cell, "tint", @tints, "#{path}[#{ci}]")

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
    rel = src |> String.trim_leading("/") |> String.split("?") |> hd()
    full = Path.join(Application.app_dir(:uitstalling, "priv/static"), rel)
    # Also check the source tree so newly-added dev assets validate before a build.
    File.exists?(full) or File.exists?(Path.join(["priv/static", rel]))
  end

  # ----- Validation helpers -------------------------------------------------

  defp req_string(map, key, path) do
    case map[key] do
      s when is_binary(s) and s != "" -> []
      _ -> ["#{path}.#{key}: required non-empty string"]
    end
  end

  defp opt_string(map, key, path) do
    case map[key] do
      nil -> []
      s when is_binary(s) -> []
      _ -> ["#{path}.#{key}: must be a string"]
    end
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
      [_ | _] = items ->
        items
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {%{} = item, i} -> fun.(item, "#{path}.#{key}[#{i}]")
          {_other, i} -> ["#{path}.#{key}[#{i}]: must be an object"]
        end)

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
