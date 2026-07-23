defmodule Uitstalling.Writing.ProjectServerTest do
  # async: false — the server runs under the app's DynamicSupervisor, so the
  # sandbox must be shared with it.
  use Uitstalling.DataCase, async: false

  import Uitstalling.Fixtures

  alias Uitstalling.Writing
  alias Uitstalling.Writing.Op
  alias Uitstalling.Writing.ProjectServer

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Uitstalling.Repo, {:shared, self()})

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Uitstalling.Writing.ServerSupervisor) do
        DynamicSupervisor.terminate_child(Uitstalling.Writing.ServerSupervisor, pid)
      end
    end)

    %{project: project} = writing_project_fixture(title: "Cached Novel")
    %{project: project}
  end

  test "serves title and docs, and caches through writes", %{project: project} do
    assert ProjectServer.title(project.id) == "Cached Novel"
    assert ProjectServer.list_docs(project.id) == []

    {:ok, doc_id} = ProjectServer.create_doc(project.id, "chapter", "One")

    # The created doc is immediately visible (cache updated in place) and its
    # body is checkable without a fresh decrypt roundtrip.
    assert [%{id: ^doc_id, title: "One", kind: "chapter"}] = ProjectServer.list_docs(project.id)
    assert {%{"blocks" => [_]}, 1, "One"} = ProjectServer.checkout_doc(project.id, doc_id)
  end

  test "apply_ops updates the cache and the word count", %{project: project} do
    {:ok, doc_id} = ProjectServer.create_doc(project.id, "chapter", "One")
    {raw, seq, _} = ProjectServer.checkout_doc(project.id, doc_id)
    [%{"id" => block}] = raw["blocks"]

    {:ok, ops} =
      Op.parse_batch([
        %{"op" => "set_field", "block" => block, "field" => "text", "value" => "one two three"}
      ])

    assert {:ok, _raw, 2} = ProjectServer.apply_ops(project.id, doc_id, ops, seq, "u1")

    # Cache reflects the write: checkout returns seq 2, list shows 3 words.
    assert {%{}, 2, "One"} = ProjectServer.checkout_doc(project.id, doc_id)
    assert [%{word_count: 3, seq: 2}] = ProjectServer.list_docs(project.id)
  end

  test "the cache matches the database (no drift)", %{project: project} do
    {:ok, doc_id} = ProjectServer.create_doc(project.id, "chapter", "One")
    {raw, seq, _} = ProjectServer.checkout_doc(project.id, doc_id)
    [%{"id" => block}] = raw["blocks"]

    {:ok, ops} =
      Op.parse_batch([
        %{"op" => "set_field", "block" => block, "field" => "text", "value" => "canonical"}
      ])

    {:ok, _, _} = ProjectServer.apply_ops(project.id, doc_id, ops, seq, "u1")

    # A direct decrypt from the DB agrees with what the server serves.
    {cached_raw, cached_seq, _} = ProjectServer.checkout_doc(project.id, doc_id)
    {db_raw, db_seq, _} = Writing.checkout_doc(project, doc_id)
    assert cached_raw == db_raw
    assert cached_seq == db_seq
  end

  test "rename and delete keep the cache honest", %{project: project} do
    {:ok, doc_id} = ProjectServer.create_doc(project.id, "chapter", "One")

    assert {:ok, "First Light", 2} =
             ProjectServer.rename_doc(project.id, doc_id, "First Light", 1, "u1")

    assert [%{title: "First Light", seq: 2}] = ProjectServer.list_docs(project.id)

    assert :ok = ProjectServer.delete_doc(project.id, doc_id)
    assert ProjectServer.list_docs(project.id) == []
  end
end
