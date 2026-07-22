defmodule Uitstalling.Writing.Op do
  @moduledoc """
  The writing edit-operation algebra (docs/writing.md): parse untrusted op
  JSON from the editor into structs, apply batches to a raw doc, invert
  applied ops for undo, and dump/load batches for the encrypted event log.

  The single trust boundary for writing edits the way `Writing.parse/2` is
  for documents. Application is structural only — "does the block/field
  exist" — the schema's rules are enforced by running `Writing.parse/2` on
  the result of every batch. Blocks are addressed by stable id, never index.
  """

  alias Uitstalling.Writing.Op.{DeleteField, InsertBlock, MoveBlock, RemoveBlock, SetField}

  @type t ::
          SetField.t()
          | DeleteField.t()
          | InsertBlock.t()
          | RemoveBlock.t()
          | MoveBlock.t()

  # Fields ops may never touch: identity and the doc version stamp.
  @forbidden_fields ~w(id v)

  @op_names %{
    SetField => "set_field",
    DeleteField => "delete_field",
    InsertBlock => "insert_block",
    RemoveBlock => "remove_block",
    MoveBlock => "move_block"
  }

  # ----- Parsing (untrusted JSON -> structs) -----------------------------------

  @doc """
  Cast a decoded JSON list of ops into structs. Returns `{:ok, ops}` or
  `{:error, [message]}` with one path-prefixed message per bad op.
  """
  def parse_batch(ops) when is_list(ops) and ops != [] do
    parsed = ops |> Enum.with_index() |> Enum.map(fn {op, i} -> parse(op, i) end)

    case Enum.split_with(parsed, &match?({:ok, _}, &1)) do
      {oks, []} -> {:ok, Enum.map(oks, fn {:ok, op} -> op end)}
      {_, errors} -> {:error, Enum.map(errors, fn {:error, message} -> message end)}
    end
  end

  def parse_batch(_ops),
    do: {:error, ["response: must be a list with at least one operation"]}

  defp parse(%{"op" => "set_field"} = op, i) do
    with {:ok, block} <- required_block(op, i),
         {:ok, field} <- field(op, i),
         :ok <- has_key(op, "value", i) do
      {:ok, %SetField{block: block, field: field, value: op["value"]}}
    end
  end

  defp parse(%{"op" => "delete_field"} = op, i) do
    with {:ok, block} <- required_block(op, i),
         {:ok, field} <- field(op, i) do
      {:ok, %DeleteField{block: block, field: field}}
    end
  end

  defp parse(%{"op" => "insert_block"} = op, i) do
    with {:ok, block} <- block_value(op, i),
         {:ok, position} <- position(op, i) do
      {:ok, %InsertBlock{block: Map.delete(block, "id"), after: position}}
    end
  end

  defp parse(%{"op" => "remove_block"} = op, i) do
    with {:ok, block} <- required_block(op, i) do
      {:ok, %RemoveBlock{block: block}}
    end
  end

  defp parse(%{"op" => "move_block"} = op, i) do
    with {:ok, block} <- required_block(op, i),
         {:ok, position} <- position(op, i) do
      {:ok, %MoveBlock{block: block, after: position}}
    end
  end

  defp parse(%{"op" => other}, i) do
    {:error,
     "ops[#{i}]: unknown op #{inspect(other)} — one of: " <>
       "set_field, delete_field, insert_block, remove_block, move_block"}
  end

  defp parse(_op, i), do: {:error, "ops[#{i}]: must be an object with an \"op\" key"}

  defp required_block(op, i) do
    case op["block"] do
      b when is_binary(b) and b != "" -> {:ok, b}
      _ -> {:error, "ops[#{i}].block: required block id string"}
    end
  end

  defp block_value(op, i) do
    case op["block"] do
      %{} = block -> {:ok, block}
      _ -> {:error, "ops[#{i}].block: required object"}
    end
  end

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

  defp position(op, i) do
    case op["after"] do
      nil -> {:ok, "end"}
      marker when marker in ["start", "end"] -> {:ok, marker}
      b when is_binary(b) and b != "" -> {:ok, b}
      _ -> {:error, "ops[#{i}].after: must be a block id, \"start\", or \"end\""}
    end
  end

  defp has_key(op, key, i) do
    if Map.has_key?(op, key), do: :ok, else: {:error, "ops[#{i}].#{key}: required"}
  end

  # ----- Event-log round-trip -----------------------------------------------------
  #
  # Applied batches live inside encrypted event payloads and must come back
  # as structs to be re-applied (undo, timeline folds). dump/load are the
  # TRUSTED counterpart of parse_batch: ids are honored, nothing is stripped.

  @doc "An applied op as a plain tagged map, ready for JSON."
  def dump(%struct{} = op) do
    op
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put("op", @op_names[struct])
  end

  @doc "Rebuild a struct from `dump/1` output (trusted, decrypted storage only)."
  def load(%{"op" => "set_field"} = m),
    do: %SetField{block: m["block"], field: m["field"], value: m["value"]}

  def load(%{"op" => "delete_field"} = m),
    do: %DeleteField{block: m["block"], field: m["field"]}

  def load(%{"op" => "insert_block"} = m),
    do: %InsertBlock{block: m["block"], after: m["after"] || "end"}

  def load(%{"op" => "remove_block"} = m), do: %RemoveBlock{block: m["block"]}

  def load(%{"op" => "move_block"} = m),
    do: %MoveBlock{block: m["block"], after: m["after"] || "end"}

  # ----- Application -----------------------------------------------------------

  @doc """
  Apply a batch atomically-in-memory: all ops succeed structurally or the
  whole batch errors (the caller never persists a partial batch). Returns
  `{:ok, new_raw, applied, inverse}` — `applied` carries realized inserts
  (minted ids filled in) and `inverse` is the batch that undoes it. Each
  op's inverse is computed against the exact state that op saw (NOT the
  batch's before-state — a later op may touch what an earlier op created),
  then reverse-concatenated.
  """
  def apply_batch(raw, ops) do
    ops
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, raw, [], []}, fn {op, i}, {:ok, acc_raw, applied, inverse} ->
      case apply_op(acc_raw, op) do
        {:ok, new_raw, realized} ->
          {:cont, {:ok, new_raw, [realized | applied], invert(realized, acc_raw) ++ inverse}}

        {:error, message} ->
          {:halt, {:error, ["ops[#{i}]: " <> message]}}
      end
    end)
    |> case do
      {:ok, new_raw, applied, inverse} -> {:ok, new_raw, Enum.reverse(applied), inverse}
      {:error, errors} -> {:error, errors}
    end
  end

  defp apply_op(raw, %SetField{} = op) do
    update_block(raw, op.block, fn block -> {:ok, Map.put(block, op.field, op.value)} end)
    |> realized(op)
  end

  defp apply_op(raw, %DeleteField{} = op) do
    update_block(raw, op.block, fn block -> {:ok, Map.delete(block, op.field)} end)
    |> realized(op)
  end

  defp apply_op(raw, %RemoveBlock{} = op) do
    case block_index(raw, op.block) do
      nil ->
        {:error, "no block with id #{inspect(op.block)}"}

      index ->
        {:ok, Map.update!(raw, "blocks", &List.delete_at(&1, index)), op}
    end
  end

  defp apply_op(raw, %InsertBlock{} = op) do
    blocks = List.wrap(raw["blocks"])

    # Parse strips ids from untrusted ops, so an id here is app-internal
    # (an inverse restoring a removed block) — honor it when free.
    id =
      case op.block["id"] do
        existing when is_binary(existing) and existing != "" ->
          if block_index(raw, existing), do: mint_block_id(blocks), else: existing

        _ ->
          mint_block_id(blocks)
      end

    block = Map.put(op.block, "id", id)

    with {:ok, index} <- insertion_index(blocks, op.after) do
      {:ok, Map.put(raw, "blocks", List.insert_at(blocks, index, block)), %{op | block: block}}
    end
  end

  defp apply_op(raw, %MoveBlock{} = op) do
    case block_index(raw, op.block) do
      nil ->
        {:error, "no block with id #{inspect(op.block)}"}

      index ->
        {item, rest} = List.pop_at(raw["blocks"], index)

        with {:ok, new_index} <- insertion_index(rest, op.after) do
          {:ok, Map.put(raw, "blocks", List.insert_at(rest, new_index, item)), op}
        end
    end
  end

  defp realized({:ok, new_raw}, op), do: {:ok, new_raw, op}
  defp realized({:error, message}, _op), do: {:error, message}

  defp update_block(raw, block_id, fun) do
    case block_index(raw, block_id) do
      nil ->
        {:error, "no block with id #{inspect(block_id)}"}

      index ->
        case fun.(Enum.at(raw["blocks"], index)) do
          {:ok, block} -> {:ok, put_in(raw, ["blocks", Access.at(index)], block)}
          {:error, message} -> {:error, message}
        end
    end
  end

  defp block_index(raw, block_id) do
    Enum.find_index(List.wrap(raw["blocks"]), &(is_map(&1) and &1["id"] == block_id))
  end

  defp insertion_index(_blocks, "start"), do: {:ok, 0}
  defp insertion_index(blocks, "end"), do: {:ok, length(blocks)}

  defp insertion_index(blocks, after_id) do
    case Enum.find_index(blocks, &(is_map(&1) and &1["id"] == after_id)) do
      nil -> {:error, "no block #{inspect(after_id)} to insert after"}
      index -> {:ok, index + 1}
    end
  end

  defp mint_block_id(blocks) do
    taken =
      for %{} = block <- blocks, is_binary(block["id"]), into: MapSet.new(), do: block["id"]

    mint_block_id(0, taken)
  end

  defp mint_block_id(n, taken) do
    id = "b#{n}"
    if MapSet.member?(taken, id), do: mint_block_id(n + 1, taken), else: id
  end

  # ----- Inversion (undo) --------------------------------------------------------

  @doc """
  The ops that undo `op`, computed against the raw the op was applied TO
  (the before-state). No-ops invert to `[]`. Inverting an applied batch =
  reversed concatenation of each op's inverse.
  """
  def invert(%SetField{} = op, raw_before) do
    case fetch_field(raw_before, op.block, op.field) do
      {:ok, old} -> [%SetField{op | value: old}]
      :missing -> [%DeleteField{block: op.block, field: op.field}]
    end
  end

  def invert(%DeleteField{} = op, raw_before) do
    case fetch_field(raw_before, op.block, op.field) do
      {:ok, old} -> [%SetField{block: op.block, field: op.field, value: old}]
      :missing -> []
    end
  end

  def invert(%RemoveBlock{} = op, raw_before) do
    blocks = List.wrap(raw_before["blocks"])

    case Enum.find_index(blocks, &(is_map(&1) and &1["id"] == op.block)) do
      nil ->
        []

      index ->
        # The removed block carries its id, which apply honors for
        # app-internal inserts — it comes back where it was, AS what it was.
        [
          %InsertBlock{
            block: Enum.at(blocks, index),
            after: position_before(blocks, index)
          }
        ]
    end
  end

  def invert(%InsertBlock{} = op, _raw_before) do
    # Only invertible once realized (apply_batch fills the minted id in).
    case op.block["id"] do
      id when is_binary(id) -> [%RemoveBlock{block: id}]
      _ -> []
    end
  end

  def invert(%MoveBlock{} = op, raw_before) do
    blocks = List.wrap(raw_before["blocks"])

    case Enum.find_index(blocks, &(is_map(&1) and &1["id"] == op.block)) do
      nil -> []
      index -> [%MoveBlock{op | after: position_before(blocks, index)}]
    end
  end

  defp fetch_field(raw, block_id, field) do
    case Enum.find(List.wrap(raw["blocks"]), &(is_map(&1) and &1["id"] == block_id)) do
      %{} = block ->
        if Map.has_key?(block, field), do: {:ok, block[field]}, else: :missing

      _ ->
        :missing
    end
  end

  defp position_before(_blocks, 0), do: "start"
  defp position_before(blocks, index), do: Enum.at(blocks, index - 1)["id"] || "start"
end
