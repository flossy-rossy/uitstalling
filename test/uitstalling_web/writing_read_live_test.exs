defmodule UitstallingWeb.WritingReadLiveTest do
  # async: false — the read view streams from the per-project ProjectServer,
  # which needs the sandbox in shared mode.
  use UitstallingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Uitstalling.Fixtures

  alias Uitstalling.Writing
  alias Uitstalling.Writing.Op

  setup %{conn: conn} do
    Ecto.Adapters.SQL.Sandbox.mode(Uitstalling.Repo, {:shared, self()})

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Uitstalling.Writing.ServerSupervisor) do
        DynamicSupervisor.terminate_child(Uitstalling.Writing.ServerSupervisor, pid)
      end
    end)

    %{user: user, project: project} = writing_project_fixture(title: "The Book")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    %{conn: conn, project: project}
  end

  defp write(project, doc_id, text) do
    {raw, seq, _} = Writing.checkout_doc(project, doc_id)
    [%{"id" => block}] = raw["blocks"]

    {:ok, ops} =
      Op.parse_batch([
        %{"op" => "set_field", "block" => block, "field" => "text", "value" => text}
      ])

    {:ok, _, _} = Writing.apply_ops(project, doc_id, ops, seq, "u1")
  end

  test "a doc's read view renders Markdown to formatted HTML", %{conn: conn, project: project} do
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    write(project, doc_id, "It began with **thunder** and *rain*.\n\n- a note\n- another")

    {:ok, view, _} = live(conn, "/write/#{project.id}/#{doc_id}/read")
    html = render_async(view)

    assert html =~ "<strong>thunder</strong>"
    assert html =~ "<em>rain</em>"
    assert html =~ "<li>a note</li>"
    assert html =~ ~s(href="/write/#{project.id}/#{doc_id}")
  end

  test "dangerous markdown link schemes are neutralised (MDEx safe mode)", %{
    conn: conn,
    project: project
  } do
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    # Literal HTML tags can't even be stored (the validator forbids them), so
    # the render-time risk is markdown constructs like a javascript: link.
    write(project, doc_id, "a [trap](javascript:alert(1)) and **bold**")

    {:ok, view, _} = live(conn, "/write/#{project.id}/#{doc_id}/read")
    html = render_async(view)

    assert html =~ "<strong>bold</strong>"
    refute html =~ "javascript:alert"
  end

  test "[[wiki-links]] resolve to matching docs; unknown ones render as dead", %{
    conn: conn,
    project: project
  } do
    {:ok, mira} = Writing.create_element(project, "character", "Mira")
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    write(project, doc_id, "[[Mira]] appears, but [[Nobody]] does not.")

    {:ok, view, _} = live(conn, "/write/#{project.id}/#{doc_id}/read")
    html = render_async(view)

    # Known title → a real link to that doc's read view.
    assert html =~ ~s(href="/write/#{project.id}/#{mira}/read" class="wikilink">Mira</a>)
    # Unknown title → styled non-link, no href.
    assert html =~ ~s(<a class="wikilink-dead")
    assert html =~ "Nobody</a>"
  end

  test "the manuscript view stitches every chapter in book order", %{conn: conn, project: project} do
    {:ok, one} = Writing.create_doc(project, "chapter", "Chapter One")
    {:ok, two} = Writing.create_doc(project, "chapter", "Chapter Two")
    write(project, one, "The **beginning**.")
    write(project, two, "The *end*.")

    {:ok, view, _} = live(conn, "/write/#{project.id}/read")
    html = render_async(view)

    assert html =~ "Chapter One"
    assert html =~ "Chapter Two"
    assert html =~ "<strong>beginning</strong>"
    assert html =~ "<em>end</em>"
    # Each chapter title links into its editor.
    assert html =~ ~s(href="/write/#{project.id}/#{one}")
    assert html =~ ~s(href="/write/#{project.id}/#{two}")
  end

  test "read view is owner-only", %{project: project} do
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    other = user_fixture()
    conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => other.id})

    assert {:error, {:redirect, %{to: "/write"}}} = live(conn, "/write/#{project.id}/read")

    assert {:error, {:redirect, %{to: "/write"}}} =
             live(conn, "/write/#{project.id}/#{doc_id}/read")
  end
end
