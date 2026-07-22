defmodule Uitstalling.Writing.OpTest do
  use ExUnit.Case, async: true

  alias Uitstalling.Writing.Op
  alias Uitstalling.Writing.Op.{DeleteField, InsertBlock, MoveBlock, RemoveBlock, SetField}

  defp doc do
    %{
      "v" => 1,
      "blocks" => [
        %{"id" => "b0", "type" => "heading", "text" => "One"},
        %{"id" => "b1", "type" => "paragraph", "text" => "It began at dusk."},
        %{"id" => "b2", "type" => "paragraph", "text" => "The road was empty."}
      ]
    }
  end

  # ----- parse_batch (untrusted JSON) --------------------------------------------

  test "parses a mixed batch" do
    assert {:ok, [%SetField{}, %InsertBlock{}, %RemoveBlock{}, %MoveBlock{}, %DeleteField{}]} =
             Op.parse_batch([
               %{"op" => "set_field", "block" => "b1", "field" => "text", "value" => "x"},
               %{"op" => "insert_block", "block" => %{"type" => "paragraph", "text" => "y"}},
               %{"op" => "remove_block", "block" => "b2"},
               %{"op" => "move_block", "block" => "b0", "after" => "end"},
               %{"op" => "delete_field", "block" => "b1", "field" => "source"}
             ])
  end

  test "strips incoming ids from insert_block (the app mints them)" do
    assert {:ok, [%InsertBlock{block: block}]} =
             Op.parse_batch([
               %{"op" => "insert_block", "block" => %{"id" => "b0", "type" => "paragraph"}}
             ])

    refute Map.has_key?(block, "id")
  end

  test "rejects forbidden fields, unknown ops, and junk" do
    assert {:error, errors} =
             Op.parse_batch([
               %{"op" => "set_field", "block" => "b1", "field" => "id", "value" => "hax"},
               %{"op" => "explode"},
               %{"op" => "set_field", "field" => "text", "value" => "no block"},
               "not an op"
             ])

    assert length(errors) == 4
    assert Enum.at(errors, 0) =~ "app-managed"
    assert Enum.at(errors, 1) =~ "unknown op"
    assert Enum.at(errors, 2) =~ "block: required"
    assert Enum.at(errors, 3) =~ "must be an object"
  end

  test "empty or non-list batches are rejected" do
    assert {:error, _} = Op.parse_batch([])
    assert {:error, _} = Op.parse_batch(%{"op" => "set_field"})
  end

  # ----- apply_batch ---------------------------------------------------------------

  test "set_field replaces a value" do
    {:ok, ops} =
      Op.parse_batch([
        %{"op" => "set_field", "block" => "b1", "field" => "text", "value" => "New."}
      ])

    assert {:ok, raw, [%SetField{}], _inverse} = Op.apply_batch(doc(), ops)
    assert Enum.at(raw["blocks"], 1)["text"] == "New."
  end

  test "insert_block mints a fresh id and honors position" do
    {:ok, ops} =
      Op.parse_batch([
        %{
          "op" => "insert_block",
          "block" => %{"type" => "paragraph", "text" => "Interlude."},
          "after" => "b0"
        }
      ])

    assert {:ok, raw, [%InsertBlock{block: %{"id" => id}}], _} = Op.apply_batch(doc(), ops)
    assert id not in ~w(b0 b1 b2)
    assert Enum.at(raw["blocks"], 1)["text"] == "Interlude."
  end

  test "a batch is atomic: one bad op fails the whole batch" do
    {:ok, ops} =
      Op.parse_batch([
        %{"op" => "set_field", "block" => "b1", "field" => "text", "value" => "kept?"},
        %{"op" => "remove_block", "block" => "nope"}
      ])

    assert {:error, [error]} = Op.apply_batch(doc(), ops)
    assert error =~ "ops[1]"
  end

  # ----- inversion ------------------------------------------------------------------

  test "the inverse of a batch restores the original doc" do
    {:ok, ops} =
      Op.parse_batch([
        %{"op" => "set_field", "block" => "b1", "field" => "text", "value" => "Rewritten."},
        %{"op" => "remove_block", "block" => "b2"},
        %{
          "op" => "insert_block",
          "block" => %{"type" => "epigraph", "text" => "quote", "source" => "someone"},
          "after" => "start"
        },
        %{"op" => "move_block", "block" => "b0", "after" => "end"}
      ])

    original = doc()
    assert {:ok, changed, _applied, inverse} = Op.apply_batch(original, ops)
    assert changed != original

    assert {:ok, restored, _applied2, _inverse2} = Op.apply_batch(changed, inverse)
    assert restored == original
  end

  test "inverse is correct when a later op touches an earlier op's insert" do
    # The pair that breaks before-state-only inversion: the set_field lands
    # on the block the insert just minted.
    {:ok, [insert]} =
      Op.parse_batch([
        %{"op" => "insert_block", "block" => %{"type" => "paragraph", "text" => ""}}
      ])

    original = doc()
    {:ok, mid, [%InsertBlock{block: %{"id" => id}}], inv1} = Op.apply_batch(original, [insert])

    set = %SetField{block: id, field: "text", value: "typed after insert"}
    {:ok, changed, _applied, inv2} = Op.apply_batch(mid, [set])

    # Undo in event order: newest inverse first.
    {:ok, back_to_mid, _, _} = Op.apply_batch(changed, inv2)
    assert back_to_mid == mid
    {:ok, restored, _, _} = Op.apply_batch(back_to_mid, inv1)
    assert restored == original
  end

  test "a removed block returns with its original id" do
    {:ok, ops} = Op.parse_batch([%{"op" => "remove_block", "block" => "b1"}])

    {:ok, changed, _applied, inverse} = Op.apply_batch(doc(), ops)
    {:ok, restored, _, _} = Op.apply_batch(changed, inverse)

    assert restored == doc()
    assert Enum.at(restored["blocks"], 1)["id"] == "b1"
  end

  # ----- dump/load (event-log round-trip) ----------------------------------------------

  test "dump/load roundtrips every op type through JSON" do
    ops = [
      %SetField{block: "b1", field: "text", value: "x"},
      %DeleteField{block: "b1", field: "source"},
      %InsertBlock{block: %{"id" => "b9", "type" => "paragraph", "text" => "y"}, after: "b0"},
      %RemoveBlock{block: "b2"},
      %MoveBlock{block: "b0", after: "start"}
    ]

    reloaded =
      ops
      |> Enum.map(&Op.dump/1)
      |> Jason.encode!()
      |> Jason.decode!()
      |> Enum.map(&Op.load/1)

    assert reloaded == ops
  end
end
