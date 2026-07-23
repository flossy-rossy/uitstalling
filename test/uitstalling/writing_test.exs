defmodule Uitstalling.WritingTest do
  use Uitstalling.DataCase, async: true

  import Uitstalling.Fixtures

  alias Uitstalling.Repo
  alias Uitstalling.Writing
  alias Uitstalling.Writing.{Doc, Event, Op}

  defp ops!(json_ops) do
    {:ok, ops} = Op.parse_batch(json_ops)
    ops
  end

  defp set_text(block, text),
    do: %{"op" => "set_field", "block" => block, "field" => "text", "value" => text}

  # ----- projects -----------------------------------------------------------------

  test "projects roundtrip their title and never store it in the clear" do
    %{user: user, project: project} = writing_project_fixture(title: "The Hollow Coast")

    assert Writing.project_title(project) == "The Hollow Coast"

    # At-rest check: nothing recognizable in the encrypted columns.
    refute project.title_enc =~ "Hollow"

    assert [%{title: "The Hollow Coast", theme: "paper", font: "literata"}] =
             Writing.list_projects(user.id)
  end

  test "projects are scoped to their owner" do
    %{project: project} = writing_project_fixture()
    other = user_fixture()

    refute Writing.owned_by?(project.id, other.id)
    refute Writing.owned_by?(project.id, nil)
    assert_raise Ecto.NoResultsError, fn -> Writing.get_project!(project.id, other.id) end
  end

  test "theme and font accept only the catalog" do
    %{user: user, project: project} = writing_project_fixture()

    assert :ok = Writing.set_theme(project, "plain")
    assert :ok = Writing.set_font(project, "garamond")
    assert [%{theme: "plain", font: "garamond"}] = Writing.list_projects(user.id)

    assert_raise FunctionClauseError, fn -> Writing.set_theme(project, "hotdog") end
  end

  test "deleting a project cascades docs and events" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")

    assert :ok = Writing.delete_project(project)
    assert Repo.all(Doc) == []
    assert Repo.all(from(e in Event, where: e.doc_id == ^doc_id)) == []
  end

  # ----- docs ---------------------------------------------------------------------

  test "a fresh doc is one empty paragraph at seq 1 with a doc.created event" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "Chapter One")

    {raw, seq, title} = Writing.checkout_doc(project, doc_id)

    assert seq == 1
    assert title == "Chapter One"
    assert [%{"type" => "paragraph", "text" => "", "id" => _}] = raw["blocks"]
    assert [%{seq: 1, type: "doc.created"}] = Writing.events(project, doc_id)
  end

  test "doc bodies and event payloads are ciphertext at rest" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    {raw, seq, _} = Writing.checkout_doc(project, doc_id)
    [%{"id" => block}] = raw["blocks"]

    {:ok, _, _} =
      Writing.apply_ops(project, doc_id, ops!([set_text(block, "A secret sentence.")]), seq, "u1")

    doc = Repo.get!(Doc, doc_id)
    refute doc.data_enc =~ "secret"
    refute doc.title_enc =~ "One"

    for event <- Repo.all(from(e in Event, where: e.doc_id == ^doc_id)) do
      refute event.payload_enc =~ "secret"
    end
  end

  test "docs list per kind with positions and word counts" do
    %{project: project} = writing_project_fixture()
    {:ok, c1} = Writing.create_doc(project, "chapter", "One")
    {:ok, c2} = Writing.create_doc(project, "chapter", "Two")
    {:ok, p1} = Writing.create_doc(project, "planning", "Outline")

    {raw, seq, _} = Writing.checkout_doc(project, c1)
    [%{"id" => block}] = raw["blocks"]

    {:ok, _, _} =
      Writing.apply_ops(project, c1, ops!([set_text(block, "five words are in here")]), seq, "u1")

    docs = Writing.list_docs(project)

    assert [
             %{id: ^c1, kind: "chapter", position: 0, word_count: 5},
             %{id: ^c2, kind: "chapter", position: 1},
             %{id: ^p1, kind: "planning", position: 0}
           ] = docs
  end

  test "docs are scoped to their project" do
    %{project: project} = writing_project_fixture()
    %{project: other_project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")

    assert_raise Ecto.NoResultsError, fn -> Writing.get_doc!(other_project, doc_id) end
  end

  # ----- the write path -------------------------------------------------------------

  test "apply_ops appends an event and bumps seq; a stale seq is refused" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    {raw, seq, _} = Writing.checkout_doc(project, doc_id)
    [%{"id" => block}] = raw["blocks"]

    assert {:ok, raw2, 2} =
             Writing.apply_ops(project, doc_id, ops!([set_text(block, "First.")]), seq, "u1")

    assert Enum.at(raw2["blocks"], 0)["text"] == "First."

    # Replaying against the old seq loses.
    assert {:error, :stale} =
             Writing.apply_ops(project, doc_id, ops!([set_text(block, "Second.")]), seq, "u1")

    assert [%{seq: 2, type: "ops.applied", actor: "u1"}, %{seq: 1}] =
             Writing.events(project, doc_id)
  end

  test "a batch whose result breaks the schema is rejected whole" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    {raw, seq, _} = Writing.checkout_doc(project, doc_id)
    [%{"id" => block}] = raw["blocks"]

    # HTML is rejected by the validator, not silently stored.
    assert {:error, [error]} =
             Writing.apply_ops(
               project,
               doc_id,
               ops!([set_text(block, "<script>alert(1)</script>")]),
               seq,
               "u1"
             )

    assert error =~ "HTML tags are not allowed"

    # Planning-only block types don't validate in a chapter.
    assert {:error, [error]} =
             Writing.apply_ops(
               project,
               doc_id,
               ops!([
                 %{
                   "op" => "insert_block",
                   "block" => %{"type" => "character", "name" => "Mira", "text" => "wary"}
                 }
               ]),
               seq,
               "u1"
             )

    assert error =~ ~s("character")

    # Nothing landed: seq unchanged, no new events.
    {_, ^seq, _} = Writing.checkout_doc(project, doc_id)
    assert [%{seq: 1}] = Writing.events(project, doc_id)
  end

  test "planning sheets accept character and beat cards" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "planning", "Outline")
    {_raw, seq, _} = Writing.checkout_doc(project, doc_id)

    assert {:ok, raw, 2} =
             Writing.apply_ops(
               project,
               doc_id,
               ops!([
                 %{
                   "op" => "insert_block",
                   "block" => %{"type" => "character", "name" => "Mira", "text" => "wary, kind"}
                 },
                 %{
                   "op" => "insert_block",
                   "block" => %{"type" => "beat", "label" => "Inciting", "text" => "the letter"}
                 }
               ]),
               seq,
               "u1"
             )

    types = Enum.map(raw["blocks"], & &1["type"])
    assert "character" in types and "beat" in types
  end

  test "rename_doc is an event and CAS'd like any other write" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")

    assert {:ok, "First Light", 2} = Writing.rename_doc(project, doc_id, "First Light", 1, "u1")
    assert {:error, :stale} = Writing.rename_doc(project, doc_id, "Late", 1, "u1")
    assert {:error, ["title: required"]} = Writing.rename_doc(project, doc_id, "  ", 2, "u1")

    {_, 2, "First Light"} = Writing.checkout_doc(project, doc_id)
    assert [%{seq: 2, type: "title.set"}, %{seq: 1}] = Writing.events(project, doc_id)
  end

  # ----- undo ------------------------------------------------------------------------

  test "undo walks back edit by edit, as appended events" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    {raw, seq, _} = Writing.checkout_doc(project, doc_id)
    [%{"id" => block}] = raw["blocks"]

    {:ok, _, seq} =
      Writing.apply_ops(project, doc_id, ops!([set_text(block, "First.")]), seq, "u1")

    {:ok, _, seq} =
      Writing.apply_ops(project, doc_id, ops!([set_text(block, "Second.")]), seq, "u1")

    assert {:ok, raw, seq} = Writing.undo(project, doc_id, seq, "u1")
    assert Enum.at(raw["blocks"], 0)["text"] == "First."

    assert {:ok, raw, seq} = Writing.undo(project, doc_id, seq, "u1")
    assert Enum.at(raw["blocks"], 0)["text"] == ""

    # Both edits are undone; history only grew.
    assert {:error, :nothing_to_undo} = Writing.undo(project, doc_id, seq, "u1")

    assert [
             %{seq: 5, type: "undo", undoes: 2},
             %{seq: 4, type: "undo", undoes: 3},
             %{seq: 3, type: "ops.applied"},
             %{seq: 2, type: "ops.applied"},
             %{seq: 1, type: "doc.created"}
           ] = Writing.events(project, doc_id)
  end

  test "undo restores removed blocks with their identity" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    {raw, seq, _} = Writing.checkout_doc(project, doc_id)
    [%{"id" => block}] = raw["blocks"]

    {:ok, raw, seq} =
      Writing.apply_ops(
        project,
        doc_id,
        ops!([
          set_text(block, "Kept."),
          %{"op" => "insert_block", "block" => %{"type" => "paragraph", "text" => "Doomed."}}
        ]),
        seq,
        "u1"
      )

    doomed = List.last(raw["blocks"])["id"]

    {:ok, _, seq} =
      Writing.apply_ops(
        project,
        doc_id,
        ops!([%{"op" => "remove_block", "block" => doomed}]),
        seq,
        "u1"
      )

    {:ok, raw, _seq} = Writing.undo(project, doc_id, seq, "u1")
    assert %{"id" => ^doomed, "text" => "Doomed."} = List.last(raw["blocks"])
  end

  test "undo is CAS'd too" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    {raw, seq, _} = Writing.checkout_doc(project, doc_id)
    [%{"id" => block}] = raw["blocks"]

    {:ok, _, new_seq} =
      Writing.apply_ops(project, doc_id, ops!([set_text(block, "First.")]), seq, "u1")

    assert {:error, :stale} = Writing.undo(project, doc_id, new_seq - 1, "u1")
  end

  # ----- redo --------------------------------------------------------------------------

  test "redo re-applies the last undone edit; chains with undo" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    {raw, seq, _} = Writing.checkout_doc(project, doc_id)
    [%{"id" => block}] = raw["blocks"]

    {:ok, _, seq} =
      Writing.apply_ops(project, doc_id, ops!([set_text(block, "First.")]), seq, "u1")

    {:ok, _, seq} =
      Writing.apply_ops(project, doc_id, ops!([set_text(block, "Second.")]), seq, "u1")

    # Nothing undone yet → nothing to redo.
    assert {:error, :nothing_to_redo} = Writing.redo(project, doc_id, seq, "u1")

    {:ok, raw, seq} = Writing.undo(project, doc_id, seq, "u1")
    assert Enum.at(raw["blocks"], 0)["text"] == "First."

    # Redo brings "Second." back.
    assert {:ok, raw, seq} = Writing.redo(project, doc_id, seq, "u1")
    assert Enum.at(raw["blocks"], 0)["text"] == "Second."

    # Undo twice, redo twice → walks the whole stack in both directions.
    {:ok, _, seq} = Writing.undo(project, doc_id, seq, "u1")
    {:ok, raw, seq} = Writing.undo(project, doc_id, seq, "u1")
    assert Enum.at(raw["blocks"], 0)["text"] == ""

    {:ok, _, seq} = Writing.redo(project, doc_id, seq, "u1")
    {:ok, raw, seq} = Writing.redo(project, doc_id, seq, "u1")
    assert Enum.at(raw["blocks"], 0)["text"] == "Second."

    assert {:error, :nothing_to_redo} = Writing.redo(project, doc_id, seq, "u1")
  end

  test "a fresh edit after undo branches history — redo is no longer offered" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    {raw, seq, _} = Writing.checkout_doc(project, doc_id)
    [%{"id" => block}] = raw["blocks"]

    {:ok, _, seq} =
      Writing.apply_ops(project, doc_id, ops!([set_text(block, "First.")]), seq, "u1")

    {:ok, _, seq} = Writing.undo(project, doc_id, seq, "u1")

    # Type something new instead of redoing…
    {:ok, _, seq} =
      Writing.apply_ops(project, doc_id, ops!([set_text(block, "Detour.")]), seq, "u1")

    # …and the old redo is gone (the branch was abandoned).
    assert {:error, :nothing_to_redo} = Writing.redo(project, doc_id, seq, "u1")

    # But undo still works on the new edit.
    {:ok, raw, _seq} = Writing.undo(project, doc_id, seq, "u1")
    assert Enum.at(raw["blocks"], 0)["text"] == ""
  end

  # ----- timeline ----------------------------------------------------------------------

  test "doc_at reconstructs any historical state" do
    %{project: project} = writing_project_fixture()
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    {raw, seq, _} = Writing.checkout_doc(project, doc_id)
    [%{"id" => block}] = raw["blocks"]

    {:ok, raw_v2, seq} =
      Writing.apply_ops(project, doc_id, ops!([set_text(block, "First.")]), seq, "u1")

    {:ok, raw_v3, seq} =
      Writing.apply_ops(
        project,
        doc_id,
        ops!([%{"op" => "insert_block", "block" => %{"type" => "heading", "text" => "II"}}]),
        seq,
        "u1"
      )

    assert {:ok, at1} = Writing.doc_at(project, doc_id, 1)
    assert [%{"text" => ""}] = at1["blocks"]

    assert {:ok, ^raw_v2} = Writing.doc_at(project, doc_id, 2)
    assert {:ok, ^raw_v3} = Writing.doc_at(project, doc_id, seq)
  end

  # ----- plan elements & links --------------------------------------------------------

  test "elements are docs with a typed badge; the type is enforced" do
    %{project: project} = writing_project_fixture()

    {:ok, order} = Writing.create_element(project, "faction", "The Order")

    assert %{kind: "element", element_type: "faction", title: "The Order"} =
             Writing.list_docs(project) |> Enum.find(&(&1.id == order))

    # Full doc machinery: elements have bodies, events, undo.
    {raw, seq, "The Order"} = Writing.checkout_doc(project, order)
    [%{"id" => block}] = raw["blocks"]

    assert {:ok, _, 2} =
             Writing.apply_ops(
               project,
               order,
               ops!([set_text(block, "Cloaked and humorless.")]),
               seq,
               "u1"
             )

    # Types are per-user now: the context validates the type STRUCTURALLY
    # (a slug), not against a fixed enum — the "may this user use it" gate
    # lives at the LiveView. So a well-formed custom-shaped key is accepted…
    assert {:ok, _} = Writing.create_element(project, "spaceship", "Nought")

    # …but a non-slug is rejected, and the element/kind rules still hold.
    assert {:error, ["element_type: invalid"]} =
             Writing.create_element(project, "Not A Slug!", "Nope")

    assert {:error, ["element_type: required"]} = Writing.create_doc(project, "element", "Nope")

    assert {:error, ["element_type: only element docs have one"]} =
             Writing.create_doc(project, "chapter", "Nope", element_type: "character")
  end

  test "a character opens as a profile: portrait slot + the standard fields" do
    %{project: project} = writing_project_fixture()
    {:ok, mira} = Writing.create_element(project, "character", "Mira")

    {raw, 1, "Mira"} = Writing.checkout_doc(project, mira)

    assert [
             %{"type" => "portrait"},
             %{"type" => "field", "label" => "Background"},
             %{"type" => "field", "label" => "Physicality"},
             %{"type" => "field", "label" => "Traits"},
             %{"type" => "paragraph"}
           ] = raw["blocks"]
  end

  test "portrait and node blocks validate their shapes" do
    %{project: project} = writing_project_fixture()
    {:ok, mira} = Writing.create_element(project, "character", "Mira")
    {raw, seq, _} = Writing.checkout_doc(project, mira)
    [%{"id" => portrait} | _] = raw["blocks"]

    # A portrait only accepts real image ids.
    assert {:error, [error]} =
             Writing.apply_ops(
               project,
               mira,
               ops!([
                 %{
                   "op" => "set_field",
                   "block" => portrait,
                   "field" => "image",
                   "value" => "https://evil.example/x.png"
                 }
               ]),
               seq,
               "u1"
             )

    assert error =~ "not a valid image id"

    # Nodes live on plan maps only, with bounded numeric coordinates.
    {:ok, map_id} = Writing.create_doc(project, "planning", "People")
    {_raw, map_seq, _} = Writing.checkout_doc(project, map_id)

    node = %{
      "op" => "insert_block",
      "block" => %{"type" => "node", "doc" => mira, "x" => 100, "y" => "nope"}
    }

    assert {:error, [error]} = Writing.apply_ops(project, map_id, ops!([node]), map_seq, "u1")
    assert error =~ ".y: must be a number"

    good = put_in(node, ["block", "y"], 200)
    assert {:ok, raw, _} = Writing.apply_ops(project, map_id, ops!([good]), map_seq, "u1")
    assert [%{"type" => "node", "doc" => ^mira, "x" => 100, "y" => 200}] = raw["blocks"]

    # …and never in a chapter.
    {:ok, chapter} = Writing.create_doc(project, "chapter", "One")
    {_chapter_raw, chapter_seq, _} = Writing.checkout_doc(project, chapter)

    assert {:error, [error]} =
             Writing.apply_ops(project, chapter, ops!([good]), chapter_seq, "u1")

    assert error =~ ~s("node")
  end

  test "images roundtrip encrypted and are scoped to their project" do
    %{project: project} = writing_project_fixture()
    %{project: other_project} = writing_project_fixture()

    png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "fake image bytes">>

    assert {:ok, image_id} = Writing.put_image(project, png)
    assert {"image/png", ^png} = Writing.get_image(project, image_id)
    assert Writing.get_image(other_project, image_id) == nil

    # Ciphertext at rest, magic bytes enforced, size capped.
    image = Repo.get!(Uitstalling.Writing.Image, image_id)
    refute image.data_enc =~ "fake image bytes"
    assert {:error, "not a PNG" <> _} = Writing.put_image(project, "just text")

    assert {:error, "image is too large" <> _} =
             Writing.put_image(project, String.duplicate("a", 3_000_001))
  end

  test "linking is idempotent, undirected in effect, and scoped to the project" do
    %{project: project} = writing_project_fixture()
    %{project: other_project} = writing_project_fixture()

    {:ok, chapter} = Writing.create_doc(project, "chapter", "One")
    {:ok, mira} = Writing.create_element(project, "character", "Mira")
    {:ok, foreign} = Writing.create_doc(other_project, "chapter", "Elsewhere")

    assert :ok = Writing.link(project, chapter, mira)
    # Same pair again, either direction: no duplicate edge.
    assert :ok = Writing.link(project, chapter, mira)
    assert :ok = Writing.link(project, mira, chapter)
    assert [_only_one] = Repo.all(Uitstalling.Writing.Link)

    assert {:error, :self_link} = Writing.link(project, mira, mira)
    assert {:error, :not_found} = Writing.link(project, chapter, foreign)
    assert {:error, :not_found} = Writing.link(other_project, chapter, mira)

    # Both sides see the link with decrypted titles.
    assert [%{id: ^mira, title: "Mira", element_type: "character"}] =
             Writing.linked_docs(project, chapter)

    assert [%{id: ^chapter, title: "One", kind: "chapter"}] = Writing.linked_docs(project, mira)

    assert :ok = Writing.unlink(project, mira, chapter)
    assert Writing.linked_docs(project, chapter) == []
  end

  test "the graph holds every element plus only linked chapters" do
    %{project: project} = writing_project_fixture()

    {:ok, tagged} = Writing.create_doc(project, "chapter", "Tagged")
    {:ok, _lone_chapter} = Writing.create_doc(project, "chapter", "Lone")
    {:ok, mira} = Writing.create_element(project, "character", "Mira")
    {:ok, order} = Writing.create_element(project, "faction", "The Order")
    {:ok, grief} = Writing.create_element(project, "theme", "Grief")

    :ok = Writing.link(project, tagged, mira)
    :ok = Writing.link(project, mira, order)

    %{nodes: nodes, edges: edges} = Writing.graph(project)

    # Every element (linked or not) + only the chapters that carry a link.
    assert Enum.sort(Enum.map(nodes, & &1.id)) == Enum.sort([tagged, mira, order, grief])
    assert %{title: "Tagged", type: "chapter"} = Enum.find(nodes, &(&1.id == tagged))
    assert %{title: "Grief", type: "theme"} = Enum.find(nodes, &(&1.id == grief))
    assert length(edges) == 2
  end

  test "deleting a doc removes its links" do
    %{project: project} = writing_project_fixture()
    {:ok, chapter} = Writing.create_doc(project, "chapter", "One")
    {:ok, mira} = Writing.create_element(project, "character", "Mira")
    :ok = Writing.link(project, chapter, mira)

    :ok = Writing.delete_doc(project, mira)
    assert Writing.linked_docs(project, chapter) == []
    assert Repo.all(Uitstalling.Writing.Link) == []
  end

  # ----- words ---------------------------------------------------------------------------

  test "count_words sums prose-bearing fields" do
    raw = %{
      "blocks" => [
        %{"id" => "b0", "type" => "heading", "text" => "Chapter One"},
        %{"id" => "b1", "type" => "paragraph", "text" => "Four words right here."},
        %{"id" => "b2", "type" => "scene_break"},
        %{"id" => "b3", "type" => "character", "name" => "Mira", "text" => "wary and kind"}
      ]
    }

    assert Writing.count_words(raw) == 2 + 4 + 1 + 3
  end
end
