defmodule UitstallingWeb.WritingLiveTest do
  use UitstallingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Uitstalling.Fixtures

  alias Uitstalling.Writing

  setup %{conn: conn} do
    %{user: user, project: project} = writing_project_fixture(title: "The Hollow Coast")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    %{conn: conn, user: user, project: project}
  end

  describe "privacy: /write is never public" do
    test "anonymous visitors are sent to sign in", %{project: project} do
      for path <- ["/write", "/write/#{project.id}"] do
        assert {:error, {:redirect, %{to: "/auth/login?return_to=" <> _}}} =
                 live(build_conn(), path)
      end
    end

    test "another signed-in user cannot open someone's project", %{project: project} do
      other = user_fixture()
      conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => other.id})

      assert {:error, {:redirect, %{to: "/write"}}} = live(conn, "/write/#{project.id}")
      assert {:error, {:redirect, %{to: "/write"}}} = live(conn, "/write/#{project.id}/whatever")
    end
  end

  test "the shelf lists projects and creates new ones", %{conn: conn} do
    {:ok, view, html} = live(conn, "/write")

    assert html =~ "The Hollow Coast"

    assert {:error, {:live_redirect, %{to: "/write/" <> _id}}} =
             view
             |> element("form[phx-submit=create_project]")
             |> render_submit(%{title: "Second"})
  end

  test "the project page creates chapters and planning sheets", %{conn: conn, project: project} do
    {:ok, view, html} = live(conn, "/write/#{project.id}")

    assert html =~ "The Hollow Coast"

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> form("#new-chapter-form", %{title: "One"}) |> render_submit()

    assert to =~ "/write/#{project.id}/"
    assert [%{kind: "chapter", title: "One"}] = Writing.list_docs(project)
  end

  describe "the editor" do
    setup %{project: project} do
      {:ok, doc_id} = Writing.create_doc(project, "chapter", "Chapter One")
      %{doc_id: doc_id}
    end

    test "mounts with the doc and saves typed text as ops", %{
      conn: conn,
      project: project,
      doc_id: doc_id
    } do
      {:ok, view, html} = live(conn, "/write/#{project.id}/#{doc_id}")

      assert html =~ "Chapter One"
      assert html =~ "0 words"

      {raw, _seq, _} = Writing.checkout_doc(project, doc_id)
      [%{"id" => block}] = raw["blocks"]

      render_hook(view, "save_block", %{
        "id" => block,
        "field" => "text",
        "value" => "It began, as these things do, at dusk."
      })

      {raw, seq, _} = Writing.checkout_doc(project, doc_id)
      assert seq == 2
      assert [%{"text" => "It began, as these things do, at dusk."}] = raw["blocks"]
      assert render(view) =~ "8 words"
    end

    test "Enter splits a paragraph; Backspace-at-start merges it back", %{
      conn: conn,
      project: project,
      doc_id: doc_id
    } do
      {:ok, view, _html} = live(conn, "/write/#{project.id}/#{doc_id}")

      {raw, _seq, _} = Writing.checkout_doc(project, doc_id)
      [%{"id" => block}] = raw["blocks"]

      render_hook(view, "split_block", %{
        "id" => block,
        "text" => "One half. Other half.",
        "at" => 10
      })

      {raw, _seq, _} = Writing.checkout_doc(project, doc_id)

      assert [%{"text" => "One half. "}, %{"id" => second, "text" => "Other half."}] =
               raw["blocks"]

      render_hook(view, "merge_block", %{"id" => second, "text" => "Other half."})

      {raw, _seq, _} = Writing.checkout_doc(project, doc_id)
      assert [%{"text" => "One half. Other half."}] = raw["blocks"]
    end

    test "undo works from the UI and survives a remount (event log, not socket)", %{
      conn: conn,
      project: project,
      doc_id: doc_id
    } do
      {:ok, view, _html} = live(conn, "/write/#{project.id}/#{doc_id}")

      {raw, _seq, _} = Writing.checkout_doc(project, doc_id)
      [%{"id" => block}] = raw["blocks"]

      render_hook(view, "save_block", %{"id" => block, "field" => "text", "value" => "Draft one."})

      # A fresh mount (refresh) can still undo — the stack is the event log.
      {:ok, view2, _} = live(conn, "/write/#{project.id}/#{doc_id}")
      view2 |> element("button[phx-click=undo]") |> render_click()

      {raw, _seq, _} = Writing.checkout_doc(project, doc_id)
      assert [%{"text" => ""}] = raw["blocks"]
    end

    test "chapters tag plan elements, both pages see the link, untag removes it", %{
      conn: conn,
      project: project,
      doc_id: doc_id
    } do
      {:ok, mira} = Writing.create_element(project, "character", "Mira")
      {:ok, view, _html} = live(conn, "/write/#{project.id}/#{doc_id}")

      # Picker offers the element; tagging links them.
      html = view |> element("button[phx-click=toggle_tag_picker]") |> render_click()
      assert html =~ "Mira"

      render_hook(view, "add_tag", %{"id" => mira})
      assert [%{id: ^mira, title: "Mira"}] = Writing.linked_docs(project, doc_id)
      assert render(view) =~ "Mira"

      # The element's page shows the chapter back (and its type badge).
      {:ok, _view, element_html} = live(conn, "/write/#{project.id}/#{mira}")
      assert element_html =~ "Chapter One"
      assert element_html =~ "character"

      render_hook(view, "remove_tag", %{"id" => mira})
      assert Writing.linked_docs(project, doc_id) == []
    end

    test "create_and_tag mints a new element of the picked type and links it", %{
      conn: conn,
      project: project,
      doc_id: doc_id
    } do
      {:ok, view, _html} = live(conn, "/write/#{project.id}/#{doc_id}")

      render_hook(view, "pick_tag_type", %{"type" => "faction"})
      render_hook(view, "create_and_tag", %{"name" => "The Order"})

      assert [%{title: "The Order", element_type: "faction"}] =
               Writing.linked_docs(project, doc_id)
    end

    test "adding a tag closes the picker instead of leaving it hanging open", %{
      conn: conn,
      project: project,
      doc_id: doc_id
    } do
      {:ok, mira} = Writing.create_element(project, "character", "Mira")
      {:ok, view, _html} = live(conn, "/write/#{project.id}/#{doc_id}")

      view |> element("button[phx-click=toggle_tag_picker]") |> render_click()
      html = render_hook(view, "add_tag", %{"id" => mira})

      refute html =~ "New element…"
      assert [%{id: ^mira}] = Writing.linked_docs(project, doc_id)
    end

    test "portraits upload encrypted and serve owner-only", %{
      conn: conn,
      project: project
    } do
      {:ok, mira} = Writing.create_element(project, "character", "Mira")
      {raw, seq, _} = Writing.checkout_doc(project, mira)
      [%{"id" => portrait} | _] = raw["blocks"]

      png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "portrait bytes">>
      {:ok, image_id} = Writing.put_image(project, png)

      {:ok, ops} =
        Uitstalling.Writing.Op.parse_batch([
          %{"op" => "set_field", "block" => portrait, "field" => "image", "value" => image_id}
        ])

      {:ok, _, _} = Writing.apply_ops(project, mira, ops, seq, "u1")

      # The editor renders the owner-only image route.
      {:ok, _view, html} = live(conn, "/write/#{project.id}/#{mira}")
      assert html =~ "/write/#{project.id}/image/#{image_id}"

      # Owner gets bytes; anyone else a 404.
      assert conn |> get("/write/#{project.id}/image/#{image_id}") |> response(200) == png

      other = user_fixture()
      other_conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => other.id})
      assert other_conn |> get("/write/#{project.id}/image/#{image_id}") |> response(404)
      assert build_conn() |> get("/write/#{project.id}/image/#{image_id}") |> response(404)
    end

    test "plan maps place, move, connect, and remove dots via undoable ops", %{
      conn: conn,
      project: project
    } do
      {:ok, mira} = Writing.create_element(project, "character", "Mira")
      {:ok, order} = Writing.create_element(project, "faction", "The Order")
      {:ok, map_id} = Writing.create_doc(project, "planning", "People")

      {:ok, view, _html} = live(conn, "/write/#{project.id}/#{map_id}")

      render_hook(view, "map_add", %{"doc" => mira})
      render_hook(view, "map_add", %{"doc" => order})
      # Same doc twice: refused.
      render_hook(view, "map_add", %{"doc" => mira})

      {raw, _seq, _} = Writing.checkout_doc(project, map_id)

      assert [%{"type" => "node", "doc" => ^mira, "id" => mira_block}, %{"doc" => ^order}] =
               raw["blocks"]

      render_hook(view, "map_move", %{"id" => mira_block, "x" => 42.4, "y" => 77.7})
      {raw, _seq, _} = Writing.checkout_doc(project, map_id)
      assert %{"x" => 42.4, "y" => 77.7} = Enum.at(raw["blocks"], 0)

      # Connecting two dots is a real project link.
      [%{"id" => a}, %{"id" => b}] = raw["blocks"]
      render_hook(view, "map_connect", %{"a" => a, "b" => b})
      assert Writing.linked?(project, mira, order)

      # Taking a dot off the map removes the block, not the element.
      render_hook(view, "map_remove", %{"id" => mira_block})
      {raw, _seq, _} = Writing.checkout_doc(project, map_id)
      assert [%{"doc" => ^order}] = raw["blocks"]
      assert Writing.get_doc!(project, mira)

      # Undo brings the dot back — layout edits ride the event log.
      view |> element("button[phx-click=undo]") |> render_click()
      {raw, _seq, _} = Writing.checkout_doc(project, map_id)
      assert [%{"doc" => ^mira}, %{"doc" => ^order}] = raw["blocks"]
    end

    test "the story map renders nodes and opens them", %{
      conn: conn,
      project: project,
      doc_id: doc_id
    } do
      {:ok, mira} = Writing.create_element(project, "character", "Mira")
      :ok = Writing.link(project, doc_id, mira)

      {:ok, view, html} = live(conn, "/write/#{project.id}/map")

      assert html =~ "Story map"
      assert html =~ "Mira"
      assert html =~ "Chapter One"

      assert {:error, {:live_redirect, %{to: to}}} =
               render_hook(view, "open_node", %{"id" => mira})

      assert to == "/write/#{project.id}/#{mira}"
    end

    test "block menu adds and retypes blocks within the kind's catalog", %{
      conn: conn,
      project: project,
      doc_id: doc_id
    } do
      {:ok, view, _html} = live(conn, "/write/#{project.id}/#{doc_id}")

      render_hook(view, "add_block", %{"type" => "heading"})
      # character cards are planning-only; a chapter refuses them.
      render_hook(view, "add_block", %{"type" => "character"})

      {raw, _seq, _} = Writing.checkout_doc(project, doc_id)
      assert Enum.map(raw["blocks"], & &1["type"]) == ["paragraph", "heading"]
    end
  end
end
