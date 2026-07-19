defmodule Uitstalling.Decks.OpTest do
  use ExUnit.Case, async: true

  alias Uitstalling.Decks.Op

  alias Uitstalling.Decks.Op.{
    DeleteField,
    InsertPart,
    MovePart,
    RemovePart,
    ReplacePart,
    SetField
  }

  defp raw do
    %{
      "title" => "T",
      "slides" => [
        %{
          "id" => "s0",
          "layout" => "flow",
          "steps" => [
            %{"id" => "p0", "actor" => "A", "body" => "first"},
            %{"id" => "p1", "actor" => "B", "body" => "second", "arrow_label" => "then"},
            %{"id" => "p2", "actor" => "C", "body" => "third"}
          ]
        },
        %{"id" => "s1", "layout" => "statement", "body" => "hello", "kicker" => "K"}
      ]
    }
  end

  defp steps(raw), do: raw["slides"] |> Enum.at(0) |> Map.fetch!("steps")

  describe "parse_batch/2" do
    test "casts valid ops into structs with the slide stamped" do
      ops = [
        %{"op" => "set_field", "field" => "body", "value" => "hi"},
        %{"op" => "set_field", "part" => "p1", "field" => "body", "value" => "hi"},
        %{"op" => "delete_field", "field" => "kicker"},
        %{"op" => "replace_part", "part" => "p0", "value" => %{"actor" => "X", "body" => "y"}},
        %{"op" => "insert_part", "list" => "steps", "part" => %{"actor" => "N", "body" => "new"}},
        %{"op" => "remove_part", "part" => "p2"},
        %{"op" => "move_part", "part" => "p0", "after" => "end"}
      ]

      assert {:ok,
              [
                %SetField{slide: "s0", part: nil},
                %SetField{part: "p1"},
                %DeleteField{field: "kicker"},
                %ReplacePart{part: "p0"},
                %InsertPart{list: "steps", after: "end"},
                %RemovePart{part: "p2"},
                %MovePart{part: "p0", after: "end"}
              ]} = Op.parse_batch(ops, "s0")
    end

    test "rejects unknown ops, forbidden fields, and malformed entries — one error each" do
      ops = [
        %{"op" => "warp_reality"},
        %{"op" => "set_field", "field" => "layout", "value" => "title"},
        %{"op" => "set_field", "field" => "image", "value" => %{}},
        %{"op" => "set_field", "field" => "body"},
        %{"op" => "insert_part", "list" => "rows", "part" => %{}},
        "not even an object"
      ]

      assert {:error, errors} = Op.parse_batch(ops, "s0")
      assert length(errors) == 6
      assert Enum.at(errors, 0) =~ "unknown op"
      assert Enum.at(errors, 1) =~ "app-managed"
      assert Enum.at(errors, 2) =~ "app-managed"
      assert Enum.at(errors, 3) =~ "value: required"
      assert Enum.at(errors, 4) =~ "list: must be one of"
      assert Enum.at(errors, 5) =~ "must be an object"
    end

    test "strips incoming ids from inserted/replacement parts" do
      ops = [
        %{
          "op" => "insert_part",
          "list" => "steps",
          "part" => %{"id" => "evil", "actor" => "N", "body" => "b"}
        },
        %{
          "op" => "replace_part",
          "part" => "p0",
          "value" => %{"id" => "evil", "actor" => "X", "body" => "y"}
        }
      ]

      assert {:ok, [%InsertPart{part: inserted}, %ReplacePart{value: replacement}]} =
               Op.parse_batch(ops, "s0")

      refute Map.has_key?(inserted, "id")
      refute Map.has_key?(replacement, "id")
    end

    test "a non-list or empty batch is a shaped error" do
      assert {:error, [error]} = Op.parse_batch(nil, "s0")
      assert error =~ ~s({"ops": [...]})
      assert {:error, _} = Op.parse_batch([], "s0")
    end
  end

  describe "apply_batch/2" do
    test "set_field on the slide and on a part" do
      {:ok, ops} =
        Op.parse_batch(
          [
            %{"op" => "set_field", "field" => "heading", "value" => "New"},
            %{"op" => "set_field", "part" => "p1", "field" => "body", "value" => "rewritten"}
          ],
          "s0"
        )

      assert {:ok, new_raw, _applied} = Op.apply_batch(raw(), ops)
      assert Enum.at(new_raw["slides"], 0)["heading"] == "New"
      assert Enum.at(steps(new_raw), 1)["body"] == "rewritten"
      # Neighbours untouched
      assert Enum.at(steps(new_raw), 0) == Enum.at(steps(raw()), 0)
    end

    test "replace_part keeps the part's id" do
      {:ok, ops} =
        Op.parse_batch(
          [
            %{"op" => "replace_part", "part" => "p1", "value" => %{"actor" => "Z", "body" => "z"}}
          ],
          "s0"
        )

      assert {:ok, new_raw, _} = Op.apply_batch(raw(), ops)
      assert Enum.at(steps(new_raw), 1) == %{"id" => "p1", "actor" => "Z", "body" => "z"}
    end

    test "insert_part mints a unique id and reports it in the applied batch" do
      {:ok, ops} =
        Op.parse_batch(
          [
            %{
              "op" => "insert_part",
              "list" => "steps",
              "after" => "p0",
              "part" => %{"actor" => "N", "body" => "new"}
            }
          ],
          "s0"
        )

      assert {:ok, new_raw, [%InsertPart{part: %{"id" => minted}}]} = Op.apply_batch(raw(), ops)
      assert minted not in ~w(p0 p1 p2)
      assert Enum.map(steps(new_raw), & &1["id"]) == ["p0", minted, "p1", "p2"]
    end

    test "insert positions: start and end" do
      {:ok, ops} =
        Op.parse_batch(
          [
            %{
              "op" => "insert_part",
              "list" => "steps",
              "after" => "start",
              "part" => %{"actor" => "S", "body" => "s"}
            },
            %{
              "op" => "insert_part",
              "list" => "steps",
              "part" => %{"actor" => "E", "body" => "e"}
            }
          ],
          "s0"
        )

      assert {:ok, new_raw, _} = Op.apply_batch(raw(), ops)
      actors = Enum.map(steps(new_raw), & &1["actor"])
      assert actors == ["S", "A", "B", "C", "E"]
    end

    test "move_part repositions within the list" do
      {:ok, ops} =
        Op.parse_batch([%{"op" => "move_part", "part" => "p2", "after" => "start"}], "s0")

      assert {:ok, new_raw, _} = Op.apply_batch(raw(), ops)
      assert Enum.map(steps(new_raw), & &1["id"]) == ["p2", "p0", "p1"]
    end

    test "unknown slide, part, or anchor is a structural error naming the op" do
      for op_json <- [
            %{"op" => "set_field", "part" => "p9", "field" => "body", "value" => "x"},
            %{"op" => "remove_part", "part" => "p9"},
            %{
              "op" => "insert_part",
              "list" => "steps",
              "after" => "p9",
              "part" => %{"actor" => "N", "body" => "b"}
            }
          ] do
        {:ok, ops} = Op.parse_batch([op_json], "s0")
        assert {:error, [error]} = Op.apply_batch(raw(), ops)
        assert error =~ "ops[0]"
        assert error =~ "p9"
      end

      {:ok, ops} = Op.parse_batch([%{"op" => "set_field", "field" => "x", "value" => 1}], "nope")
      assert {:error, [error]} = Op.apply_batch(raw(), ops)
      assert error =~ "no slide"
    end

    test "a batch is atomic: an error midway applies nothing" do
      {:ok, ops} =
        Op.parse_batch(
          [
            %{"op" => "set_field", "field" => "heading", "value" => "changed"},
            %{"op" => "remove_part", "part" => "p9"}
          ],
          "s0"
        )

      assert {:error, _} = Op.apply_batch(raw(), ops)
      # Caller discards on error — nothing was persisted; the returned error
      # is the only artifact.
    end
  end

  describe "invert/2 (undo)" do
    # Every op's inverse, applied to the op's result, restores the original.
    defp assert_roundtrip(op_json) do
      before = raw()
      {:ok, [op]} = Op.parse_batch([op_json], "s0")
      {:ok, applied_raw, [realized]} = Op.apply_batch(before, [op])

      inverses = Op.invert(realized, before)
      assert {:ok, restored, _} = Op.apply_batch(applied_raw, inverses)
      assert restored == before
    end

    test "set_field over an existing value" do
      assert_roundtrip(%{"op" => "set_field", "part" => "p1", "field" => "body", "value" => "x"})
      assert_roundtrip(%{"op" => "set_field", "field" => "heading", "value" => "x"})
    end

    test "set_field creating a new field inverts to a delete" do
      before = raw()

      {:ok, [op]} =
        Op.parse_batch([%{"op" => "set_field", "field" => "footnote", "value" => "f"}], "s0")

      {:ok, applied_raw, [realized]} = Op.apply_batch(before, [op])

      assert [%DeleteField{field: "footnote"}] = Op.invert(realized, before)
      assert {:ok, restored, _} = Op.apply_batch(applied_raw, Op.invert(realized, before))
      assert restored == before
    end

    test "delete_field restores the old value" do
      assert_roundtrip(%{"op" => "delete_field", "part" => "p1", "field" => "arrow_label"})
    end

    test "replace_part restores the old part" do
      assert_roundtrip(%{
        "op" => "replace_part",
        "part" => "p1",
        "value" => %{"actor" => "Z", "body" => "z"}
      })
    end

    test "remove_part restores the part with its original id and position" do
      for part <- ~w(p0 p1 p2) do
        assert_roundtrip(%{"op" => "remove_part", "part" => part})
      end
    end

    test "insert_part inverts to removing the minted part" do
      before = raw()

      {:ok, [op]} =
        Op.parse_batch(
          [
            %{
              "op" => "insert_part",
              "list" => "steps",
              "after" => "p0",
              "part" => %{"actor" => "N", "body" => "b"}
            }
          ],
          "s0"
        )

      {:ok, applied_raw, [realized]} = Op.apply_batch(before, [op])
      assert [%RemovePart{}] = Op.invert(realized, before)
      assert {:ok, restored, _} = Op.apply_batch(applied_raw, Op.invert(realized, before))
      assert restored == before
    end

    test "move_part inverts to moving back" do
      assert_roundtrip(%{"op" => "move_part", "part" => "p2", "after" => "start"})
      assert_roundtrip(%{"op" => "move_part", "part" => "p0", "after" => "end"})
      assert_roundtrip(%{"op" => "move_part", "part" => "p1", "after" => "p2"})
    end
  end
end
