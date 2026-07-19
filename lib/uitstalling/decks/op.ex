defmodule Uitstalling.Decks.Op do
  @moduledoc """
  The edit-operation algebra (see docs/edit-ops.md): parse untrusted op JSON
  into structs, apply batches to a raw deck, and invert applied ops for undo.

  This module is the single trust boundary for ops the way `Decks.parse/1`
  is for documents: JSON outside (model replies, future channel clients),
  structs everywhere inside. Application is structural only — "does the
  slide/part/field exist" — the design system's rules are still enforced by
  running `Decks.parse/1` on the result of every batch.

  Ops address parts by stable id (never index), minted by the app and
  backfilled by `Decks.migrate/1`. `apply_batch/2` returns the batch it
  actually performed — inserts come back carrying their minted ids — so the
  applied batch is invertible and loggable as-is.
  """

  alias Uitstalling.Decks.Op.{
    DeleteField,
    InsertPart,
    MovePart,
    RemovePart,
    ReplacePart,
    SetField
  }

  @type t ::
          SetField.t()
          | DeleteField.t()
          | InsertPart.t()
          | RemovePart.t()
          | MovePart.t()
          | ReplacePart.t()

  # Lists whose map items are id-addressable parts.
  @part_lists ~w(points steps items)

  # Fields ops may never touch: identity, layout changes (whole-slide rework
  # territory), and app-managed keys.
  @forbidden_fields ~w(id layout image image_request v)

  def part_lists, do: @part_lists

  # ----- Parsing (untrusted JSON -> structs) -----------------------------------

  @doc """
  Cast a decoded JSON list of ops into structs, stamping `slide_id` (edit
  batches are scoped to one slide; the struct field exists for future
  deck-level batches). Returns `{:ok, ops}` or `{:error, [message]}` with one
  message per bad op — shaped for the model-retry loop.
  """
  def parse_batch(ops, slide_id) when is_list(ops) and ops != [] do
    parsed = ops |> Enum.with_index() |> Enum.map(fn {op, i} -> parse(op, slide_id, i) end)

    case Enum.split_with(parsed, &match?({:ok, _}, &1)) do
      {oks, []} -> {:ok, Enum.map(oks, fn {:ok, op} -> op end)}
      {_, errors} -> {:error, Enum.map(errors, fn {:error, message} -> message end)}
    end
  end

  def parse_batch(_ops, _slide_id),
    do: {:error, ["response: must be {\"ops\": [...]} with at least one operation"]}

  defp parse(%{"op" => "set_field"} = op, slide_id, i) do
    with {:ok, field} <- field(op, i),
         {:ok, part} <- optional_part(op, i),
         :ok <- has_key(op, "value", i) do
      {:ok, %SetField{slide: slide_id, part: part, field: field, value: op["value"]}}
    end
  end

  defp parse(%{"op" => "delete_field"} = op, slide_id, i) do
    with {:ok, field} <- field(op, i),
         {:ok, part} <- optional_part(op, i) do
      {:ok, %DeleteField{slide: slide_id, part: part, field: field}}
    end
  end

  defp parse(%{"op" => "insert_part"} = op, slide_id, i) do
    with {:ok, list} <- part_list(op, i),
         {:ok, part} <- part_value(op, "part", i),
         {:ok, position} <- position(op, i) do
      {:ok,
       %InsertPart{slide: slide_id, list: list, part: Map.delete(part, "id"), after: position}}
    end
  end

  defp parse(%{"op" => "remove_part"} = op, slide_id, i) do
    with {:ok, part} <- required_part(op, i) do
      {:ok, %RemovePart{slide: slide_id, part: part}}
    end
  end

  defp parse(%{"op" => "move_part"} = op, slide_id, i) do
    with {:ok, part} <- required_part(op, i),
         {:ok, position} <- position(op, i) do
      {:ok, %MovePart{slide: slide_id, part: part, after: position}}
    end
  end

  defp parse(%{"op" => "replace_part"} = op, slide_id, i) do
    with {:ok, part} <- required_part(op, i),
         {:ok, value} <- part_value(op, "value", i) do
      {:ok, %ReplacePart{slide: slide_id, part: part, value: Map.delete(value, "id")}}
    end
  end

  defp parse(%{"op" => other}, _slide_id, i) do
    {:error,
     "ops[#{i}]: unknown op #{inspect(other)} — one of: set_field, delete_field, " <>
       "insert_part, remove_part, move_part, replace_part"}
  end

  defp parse(_op, _slide_id, i), do: {:error, "ops[#{i}]: must be an object with an \"op\" key"}

  defp field(op, i) do
    case op["field"] do
      f when is_binary(f) and f != "" and f not in @forbidden_fields ->
        {:ok, f}

      f when f in @forbidden_fields ->
        {:error, "ops[#{i}].field: #{inspect(f)} is app-managed and cannot be set by ops"}

      _ ->
        {:error, "ops[#{i}].field: required string"}
    end
  end

  defp optional_part(op, i) do
    case op["part"] do
      nil -> {:ok, nil}
      p when is_binary(p) and p != "" -> {:ok, p}
      _ -> {:error, "ops[#{i}].part: must be a part id string"}
    end
  end

  defp required_part(op, i) do
    case op["part"] do
      p when is_binary(p) and p != "" -> {:ok, p}
      _ -> {:error, "ops[#{i}].part: required part id string"}
    end
  end

  defp part_list(op, i) do
    case op["list"] do
      l when l in @part_lists -> {:ok, l}
      _ -> {:error, "ops[#{i}].list: must be one of: #{Enum.join(@part_lists, ", ")}"}
    end
  end

  defp part_value(op, key, i) do
    case op[key] do
      %{} = value -> {:ok, value}
      _ -> {:error, "ops[#{i}].#{key}: required object"}
    end
  end

  defp position(op, i) do
    case op["after"] do
      nil -> {:ok, "end"}
      marker when marker in ["start", "end"] -> {:ok, marker}
      p when is_binary(p) and p != "" -> {:ok, p}
      _ -> {:error, "ops[#{i}].after: must be a part id, \"start\", or \"end\""}
    end
  end

  defp has_key(op, key, i) do
    if Map.has_key?(op, key), do: :ok, else: {:error, "ops[#{i}].#{key}: required"}
  end

  # ----- Application -----------------------------------------------------------

  @doc """
  Apply a batch atomically-in-memory: all ops succeed structurally or the
  whole batch errors (the caller never persists a partial batch). Returns
  `{:ok, new_raw, applied}` where `applied` is the batch with inserts
  realized (minted ids filled in) — ready to invert or log.
  """
  def apply_batch(raw, ops) do
    ops
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, raw, []}, fn {op, i}, {:ok, acc_raw, applied} ->
      case apply_op(acc_raw, op) do
        {:ok, new_raw, realized} -> {:cont, {:ok, new_raw, [realized | applied]}}
        {:error, message} -> {:halt, {:error, ["ops[#{i}]: " <> message]}}
      end
    end)
    |> case do
      {:ok, new_raw, applied} -> {:ok, new_raw, Enum.reverse(applied)}
      {:error, errors} -> {:error, errors}
    end
  end

  defp apply_op(raw, %SetField{part: nil} = op) do
    update_slide(raw, op.slide, fn slide -> {:ok, Map.put(slide, op.field, op.value)} end)
    |> realized(op)
  end

  defp apply_op(raw, %SetField{} = op) do
    update_part(raw, op.slide, op.part, fn part -> {:ok, Map.put(part, op.field, op.value)} end)
    |> realized(op)
  end

  defp apply_op(raw, %DeleteField{part: nil} = op) do
    update_slide(raw, op.slide, fn slide -> {:ok, Map.delete(slide, op.field)} end)
    |> realized(op)
  end

  defp apply_op(raw, %DeleteField{} = op) do
    update_part(raw, op.slide, op.part, fn part -> {:ok, Map.delete(part, op.field)} end)
    |> realized(op)
  end

  defp apply_op(raw, %ReplacePart{} = op) do
    update_part(raw, op.slide, op.part, fn part ->
      {:ok, Map.put(op.value, "id", part["id"])}
    end)
    |> realized(op)
  end

  defp apply_op(raw, %RemovePart{} = op) do
    update_slide(raw, op.slide, fn slide ->
      case part_location(slide, op.part) do
        nil ->
          {:error, "no part #{inspect(op.part)} on slide #{inspect(op.slide)}"}

        {key, index} ->
          {:ok, Map.put(slide, key, List.delete_at(slide[key], index))}
      end
    end)
    |> realized(op)
  end

  defp apply_op(raw, %InsertPart{} = op) do
    result =
      update_slide(raw, op.slide, fn slide ->
        # Parse strips ids from untrusted ops, so an id here is app-internal
        # (an inverse restoring a removed part) — honor it when free.
        id =
          case op.part["id"] do
            existing when is_binary(existing) and existing != "" ->
              if part_location(slide, existing), do: mint_part_id(slide), else: existing

            _ ->
              mint_part_id(slide)
          end

        part = Map.put(op.part, "id", id)
        list = List.wrap(slide[op.list])

        with {:ok, index} <- insertion_index(list, op.after) do
          {:ok, Map.put(slide, op.list, List.insert_at(list, index, part)), id}
        end
      end)

    case result do
      {:ok, new_raw, id} -> {:ok, new_raw, %{op | part: Map.put(op.part, "id", id)}}
      {:ok, new_raw} -> {:ok, new_raw, op}
      {:error, message} -> {:error, message}
    end
  end

  defp apply_op(raw, %MovePart{} = op) do
    update_slide(raw, op.slide, fn slide ->
      case part_location(slide, op.part) do
        nil ->
          {:error, "no part #{inspect(op.part)} on slide #{inspect(op.slide)}"}

        {key, index} ->
          {item, rest} = List.pop_at(slide[key], index)

          with {:ok, new_index} <- insertion_index(rest, op.after) do
            {:ok, Map.put(slide, key, List.insert_at(rest, new_index, item))}
          end
      end
    end)
    |> realized(op)
  end

  defp realized({:ok, new_raw}, op), do: {:ok, new_raw, op}
  defp realized({:error, message}, _op), do: {:error, message}

  defp update_slide(raw, slide_id, fun) do
    case Enum.find_index(raw["slides"], &(is_map(&1) and &1["id"] == slide_id)) do
      nil ->
        {:error, "no slide with id #{inspect(slide_id)}"}

      index ->
        case fun.(Enum.at(raw["slides"], index)) do
          {:ok, slide} -> {:ok, put_in(raw, ["slides", Access.at(index)], slide)}
          {:ok, slide, extra} -> {:ok, put_in(raw, ["slides", Access.at(index)], slide), extra}
          {:error, message} -> {:error, message}
        end
    end
  end

  defp update_part(raw, slide_id, part_id, fun) do
    update_slide(raw, slide_id, fn slide ->
      case part_location(slide, part_id) do
        nil ->
          {:error, "no part #{inspect(part_id)} on slide #{inspect(slide_id)}"}

        {key, index} ->
          case fun.(Enum.at(slide[key], index)) do
            {:ok, part} -> {:ok, Map.put(slide, key, List.replace_at(slide[key], index, part))}
            {:error, message} -> {:error, message}
          end
      end
    end)
  end

  @doc "Where a part id lives on a slide: `{list_key, index}` or nil."
  def part_location(slide, part_id) do
    Enum.find_value(@part_lists, fn key ->
      case slide[key] do
        list when is_list(list) ->
          case Enum.find_index(list, &(is_map(&1) and &1["id"] == part_id)) do
            nil -> nil
            index -> {key, index}
          end

        _ ->
          nil
      end
    end)
  end

  defp insertion_index(_list, "start"), do: {:ok, 0}
  defp insertion_index(list, "end"), do: {:ok, length(list)}

  defp insertion_index(list, after_id) do
    case Enum.find_index(list, &(is_map(&1) and &1["id"] == after_id)) do
      nil -> {:error, "no part #{inspect(after_id)} to insert after"}
      index -> {:ok, index + 1}
    end
  end

  defp mint_part_id(slide) do
    taken =
      for key <- @part_lists,
          list = slide[key],
          is_list(list),
          %{} = item <- list,
          is_binary(item["id"]),
          into: MapSet.new(),
          do: item["id"]

    mint_part_id(0, taken)
  end

  defp mint_part_id(n, taken) do
    id = "p#{n}"
    if MapSet.member?(taken, id), do: mint_part_id(n + 1, taken), else: id
  end

  # ----- Inversion (undo) --------------------------------------------------------

  @doc """
  The ops that undo `op`, computed against the raw the op was applied TO
  (i.e. the before-state). Ops that were no-ops invert to `[]`. Inverting an
  applied batch = reversed concatenation of each op's inverse.
  """
  def invert(%SetField{} = op, raw_before) do
    case fetch_field(raw_before, op) do
      {:ok, old} -> [%SetField{op | value: old}]
      :missing -> [%DeleteField{slide: op.slide, part: op.part, field: op.field}]
    end
  end

  def invert(%DeleteField{} = op, raw_before) do
    case fetch_field(raw_before, op) do
      {:ok, old} -> [%SetField{slide: op.slide, part: op.part, field: op.field, value: old}]
      :missing -> []
    end
  end

  def invert(%ReplacePart{} = op, raw_before) do
    case find_part(raw_before, op.slide, op.part) do
      nil -> []
      {_key, _index, old} -> [%ReplacePart{op | value: old}]
    end
  end

  def invert(%RemovePart{} = op, raw_before) do
    case find_part(raw_before, op.slide, op.part) do
      nil ->
        []

      {key, index, old} ->
        # `old` carries its id, which apply honors for app-internal inserts —
        # the part comes back where it was, AS what it was.
        [
          %InsertPart{
            slide: op.slide,
            list: key,
            part: old,
            after: position_before(raw_before, op.slide, key, index)
          }
        ]
    end
  end

  def invert(%InsertPart{} = op, _raw_before) do
    # Only invertible once realized (apply_batch fills the minted id in).
    case op.part["id"] do
      id when is_binary(id) -> [%RemovePart{slide: op.slide, part: id}]
      _ -> []
    end
  end

  def invert(%MovePart{} = op, raw_before) do
    case find_part(raw_before, op.slide, op.part) do
      nil ->
        []

      {key, index, _old} ->
        [%MovePart{op | after: position_before(raw_before, op.slide, key, index)}]
    end
  end

  defp fetch_field(raw, %{slide: slide_id, part: nil, field: field}) do
    with %{} = slide <- find_slide(raw, slide_id),
         true <- Map.has_key?(slide, field) do
      {:ok, slide[field]}
    else
      _ -> :missing
    end
  end

  defp fetch_field(raw, %{slide: slide_id, part: part_id, field: field}) do
    case find_part(raw, slide_id, part_id) do
      {_key, _index, %{} = part} ->
        if Map.has_key?(part, field), do: {:ok, part[field]}, else: :missing

      nil ->
        :missing
    end
  end

  defp find_slide(raw, slide_id) do
    Enum.find(raw["slides"], &(is_map(&1) and &1["id"] == slide_id))
  end

  defp find_part(raw, slide_id, part_id) do
    with %{} = slide <- find_slide(raw, slide_id),
         {key, index} <- part_location(slide, part_id) do
      {key, index, Enum.at(slide[key], index)}
    else
      _ -> nil
    end
  end

  defp position_before(raw, slide_id, key, index) do
    if index == 0 do
      "start"
    else
      slide = find_slide(raw, slide_id)
      Enum.at(slide[key], index - 1)["id"] || "start"
    end
  end
end
