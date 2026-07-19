defmodule UitstallingWeb.DeckLiveTest do
  # async: false — these tests mutate the shared deck file
  use UitstallingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Uitstalling.Decks

  setup %{conn: conn} do
    # The session user owns the demo deck, so edit mode is available.
    %{user: user} = Uitstalling.Fixtures.demo_deck_fixture()
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    %{conn: conn, user: user}
  end

  defp deck_on_disk do
    Decks.load_raw!("demo")
  end

  test "a non-owner can view but gets no edit affordance and cannot mutate", %{conn: _conn} do
    visitor = build_conn()
    {:ok, view, html} = live(visitor, "/deck/demo")

    # Public view works, but no edit button
    assert html =~ "Phishing in 2026."
    refute html =~ "✎ edit"

    # A pushed mutation is a server-side no-op (authorize guard), deck untouched
    render_hook(view, "toggle_edit", %{})
    refute render(view) =~ "click a part to edit"

    render_hook(view, "delete_slide", %{})
    assert length(deck_on_disk()["slides"]) == 11
  end

  test "renders every slide of the demo deck", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/deck/demo")

    assert html =~ "TOTP isn&#39;t saving you."
    assert html =~ "Phishing in 2026."
    assert html =~ "✓ REGISTERED"
    assert html =~ "slide-10"

    # Inline markup is transformed, never leaked as raw marks
    # (scoped: the root layout's theme JS legitimately contains "==")
    refute html =~ "==TOTP"
    refute html =~ "==authData=="
  end

  test "keyboard nav broadcasts to the remote", %{conn: conn} do
    {:ok, deck, _html} = live(conn, "/deck/demo")
    {:ok, remote, _html} = live(conn, "/deck/demo/remote")

    render_hook(deck, "nav", %{"dir" => 1})
    assert render(deck) =~ "2 / 11"
    assert render(remote) =~ "2 / 11"
  end

  test "remote buttons drive the deck", %{conn: conn} do
    {:ok, deck, _html} = live(conn, "/deck/demo")
    {:ok, remote, _html} = live(conn, "/deck/demo/remote")

    remote |> element("button[phx-value-dir='1']") |> render_click()
    remote |> element("button[phx-value-dir='1']") |> render_click()

    assert render(remote) =~ "3 / 11"
    assert render(deck) =~ "3 / 11"
  end

  test "nav clamps at deck bounds", %{conn: conn} do
    {:ok, deck, _html} = live(conn, "/deck/demo")

    render_hook(deck, "nav", %{"dir" => -1})
    assert render(deck) =~ "1 / 11"

    for _ <- 1..50, do: render_hook(deck, "nav", %{"dir" => 1})
    assert render(deck) =~ "11 / 11"
  end

  test "clicking a block opens direct text editing with the current value", %{conn: conn} do
    {:ok, view, html} = live(conn, "/deck/demo")
    refute html =~ "click a part to edit"

    view |> element("button", "✎ edit") |> render_click()
    assert render(view) =~ "click a part to edit"

    view |> element("#slide-5 [phx-value-block='code']") |> render_click()
    html = render(view)
    assert html =~ "EDIT SLIDE 6"
    assert html =~ "· code"
    # The direct edit form is pre-filled with the raw mini-markup text
    assert html =~ "form phx-submit=\"save_text\""
    assert html =~ "==authData== || SHA-256(==clientDataJSON==)"
  end

  test "saving a scalar block edits exactly that text", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    view |> element("button", "✎ edit") |> render_click()
    view |> element("#slide-2 [phx-value-block='heading']") |> render_click()

    view
    |> element("form[phx-submit='save_text']")
    |> render_submit(%{"value" => "Phishing, ==today.=="})

    assert render(view) =~ "today."
    assert Enum.at(deck_on_disk()["slides"], 2)["heading"] == "Phishing, ==today.=="
  end

  test "saving a map block (faq item) edits its fields", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    view |> element("button", "✎ edit") |> render_click()
    view |> element("#slide-9 [phx-value-block='items.1']") |> render_click()

    view
    |> element("form[phx-submit='save_text']")
    |> render_submit(%{"q" => "Which browsers work?", "a" => "All of them since 2018."})

    item = Enum.at(deck_on_disk()["slides"], 9)["items"] |> Enum.at(1)
    # The app-assigned part id survives a manual edit untouched
    assert %{"id" => "p" <> _} = item

    assert Map.delete(item, "id") == %{
             "q" => "Which browsers work?",
             "a" => "All of them since 2018."
           }
  end

  test "saving a bullets column edits one line per bullet", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    view |> element("button", "✎ edit") |> render_click()
    view |> element("#slide-2 [phx-value-block='columns.1']") |> render_click()

    view
    |> element("form[phx-submit='save_text']")
    |> render_submit(%{"value" => "`Evilginx`\n`Tycoon`\n\nCommodity attack.\n"})

    assert Enum.at(deck_on_disk()["slides"], 2)["columns"] |> Enum.at(1) ==
             ["`Evilginx`", "`Tycoon`", "Commodity attack."]
  end

  test "queueing an agent request shows generating overlay and blocks interaction", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    view |> element("button", "✎ edit") |> render_click()
    view |> element("#slide-6 [phx-value-block='rows']") |> render_click()

    # Table rows are agent-only: no direct edit form
    refute render(view) =~ "form phx-submit=\"save_text\""

    view
    |> element("form[phx-submit='queue_edit']")
    |> render_submit(%{"prompt" => "reword this table in layman's terms"})

    html = render(view)
    assert html =~ "generating"
    assert html =~ "1 generating"

    [request] = Decks.pending_requests()
    assert request["slide_id"] == "s6"
    assert request["block"] == "rows"
    assert request["prompt"] == "reword this table in layman's terms"
    assert request["status"] == "pending"
  end

  test "slide-level panel offers the agent prompt and covers the whole slide when queued",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    view |> element("button", "✎ edit") |> render_click()
    view |> element("#slide-1 button[phx-click='select_slide']") |> render_click()

    # Slide level leads with the agent prompt, not direct text editing
    html = render(view)
    assert html =~ "DESCRIBE THE CHANGES"
    refute html =~ "form phx-submit=\"save_text\""

    view
    |> element("form[phx-submit='queue_edit']")
    |> render_submit(%{"prompt" => "make this slide about passkeys in general"})

    [request] = Decks.pending_requests()
    assert request["slide_id"] == "s1"
    assert request["block"] == nil

    # Whole slide is overlaid: its select pill is gone while busy
    html = render(view)
    assert html =~ "generating"
    refute has_element?(view, "#slide-1 button[phx-click='select_slide']")
  end

  test "the deck's worker completes a queued request and the deck updates live", %{conn: conn} do
    start_supervised!({Uitstalling.Decks.DeckWorker, "demo"})

    {:ok, view, _html} = live(conn, "/deck/demo")

    view |> element("button", "✎ edit") |> render_click()
    view |> element("#slide-1 button[phx-click='select_slide']") |> render_click()

    view
    |> element("form[phx-submit='queue_edit']")
    |> render_submit(%{"prompt" => "reword the framing"})

    # The fake agent rewrites the heading; the pipeline broadcast lands async
    assert_eventually(fn ->
      html = render(view)
      html =~ "AGENT: reword the framing" and not (html =~ "generating")
    end)

    [request] = Decks.load_requests()
    assert request["status"] == "done"
  end

  defp assert_eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        assert_eventually(fun, tries - 1)
    end
  end

  test "set_size persists to the store and undo reverts it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    view |> element("button", "✎ edit") |> render_click()
    view |> element("#slide-5 button[phx-click='select_slide']") |> render_click()
    view |> element("button[phx-value-size='sm']") |> render_click()

    assert Enum.at(deck_on_disk()["slides"], 5)["size"] == "sm"

    view |> element("button[phx-click='undo']") |> render_click()
    refute Map.has_key?(Enum.at(deck_on_disk()["slides"], 5), "size")
  end

  test "deleting an optional block persists and undo restores it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    view |> element("button", "✎ edit") |> render_click()
    view |> element("#slide-0 [phx-value-block='subheading']") |> render_click()
    view |> element("button[phx-click='delete']") |> render_click()

    refute Map.has_key?(hd(deck_on_disk()["slides"]), "subheading")
    refute render(view) =~ "A tour through WebAuthn"

    view |> element("button[phx-click='undo']") |> render_click()
    assert Map.has_key?(hd(deck_on_disk()["slides"]), "subheading")
    assert render(view) =~ "A tour through WebAuthn"
  end

  test "deleting a required block is rejected by the validator", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    view |> element("button", "✎ edit") |> render_click()
    view |> element("#slide-1 [phx-value-block='body']") |> render_click()
    view |> element("button[phx-click='delete']") |> render_click()

    assert render(view) =~ "Can&#39;t do that"
    assert Map.has_key?(Enum.at(deck_on_disk()["slides"], 1), "body")
  end

  test "deleting a list item keeps siblings; deleting a slide shrinks the deck", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    view |> element("button", "✎ edit") |> render_click()

    # Delete the 4th FAQ item (slide 9)
    view |> element("#slide-9 [phx-value-block='items.3']") |> render_click()
    view |> element("button[phx-click='delete']") |> render_click()
    assert length(Enum.at(deck_on_disk()["slides"], 9)["items"]) == 3

    # Delete the media slide entirely
    view |> element("#slide-7 button[phx-click='select_slide']") |> render_click()
    view |> element("button[phx-click='delete_slide']") |> render_click()
    assert length(deck_on_disk()["slides"]) == 10
    assert render(view) =~ "/ 10"

    # Undo twice restores both
    view |> element("button[phx-click='undo']") |> render_click()
    view |> element("button[phx-click='undo']") |> render_click()
    assert length(deck_on_disk()["slides"]) == 11
    assert length(Enum.at(deck_on_disk()["slides"], 9)["items"]) == 4
  end

  test "edits broadcast to other viewers", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")
    {:ok, other, _html} = live(conn, "/deck/demo")

    view |> element("button", "✎ edit") |> render_click()
    view |> element("#slide-0 [phx-value-block='subheading']") |> render_click()
    view |> element("button[phx-click='delete']") |> render_click()

    refute render(other) =~ "A tour through WebAuthn"
  end

  test "inline markup emits no whitespace between runs" do
    # Template whitespace between runs renders literally inside
    # whitespace-pre-wrap (big_code) and as mid-sentence gaps elsewhere.
    {:ok, deck} =
      Uitstalling.Decks.parse(%{
        "title" => "x",
        "slides" => [
          %{"layout" => "big_code", "code" => "==authData== || SHA-256(==clientDataJSON==)"}
        ]
      })

    html =
      Phoenix.LiveViewTest.render_component(&UitstallingWeb.DeckComponents.slide/1,
        deck: deck,
        slide: hd(deck.slides),
        index: 0
      )

    [_, code] = Regex.run(~r/<code[^>]*whitespace-pre-wrap[^>]*>(.*?)<\/code>/s, html)
    text = code |> String.replace(~r/<[^>]+>/, "") |> String.replace("&amp;", "&")
    assert text == "authData || SHA-256(clientDataJSON)"
  end

  test "an image can be added to any slide via upload, renders, and deletes", %{conn: conn} do
    on_exit(fn -> File.rm_rf("tmp/test-uploads") end)
    {:ok, view, _html} = live(conn, "/deck/demo")

    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_slide", %{"index" => 1})
    assert render(view) =~ "+ image"

    view |> element("button[phx-value-key='image']") |> render_click()
    assert render(view) =~ "UPLOAD AN IMAGE"

    png = <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR">>

    image =
      file_input(view, "#image-form", :image, [
        %{name: "pic.png", content: png, type: "image/png"}
      ])

    render_upload(image, "pic.png")

    view
    |> form("#image-form", %{"alt" => "an uploaded test image"})
    |> render_submit()

    slide = Enum.at(deck_on_disk()["slides"], 1)
    assert %{"asset_id" => "ast_" <> _} = slide["image"]

    html = render(view)
    assert html =~ "/a/#{slide["image"]["asset_id"]}"
    assert html =~ "an uploaded test image"

    # Delete via the standard block delete path
    render_hook(view, "select_block", %{"index" => 1, "block" => "image"})
    render_hook(view, "delete", %{})
    refute Map.has_key?(Enum.at(deck_on_disk()["slides"], 1), "image")
  end

  test "describing an image queues a generation request and shows the spinner", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_slide", %{"index" => 1})
    view |> element("button[phx-value-key='image']") |> render_click()

    view
    |> form("#image-gen-form", %{"prompt" => "an isometric phishing diagram"})
    |> render_submit()

    [request] = Decks.pending_requests()
    assert request["type"] == "asset"
    assert request["slide_id"] == "s1"
    assert request["block"] == "image"
    assert request["prompt"] == "an isometric phishing diagram"

    # The image slot renders with the generating overlay while pending
    html = render(view)
    assert html =~ "generating"
    assert html =~ "image on its way"
  end

  test "a queued generation can be canceled from the pending badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_slide", %{"index" => 1})
    view |> element("button[phx-value-key='image']") |> render_click()

    view
    |> form("#image-gen-form", %{"prompt" => "something slow"})
    |> render_submit()

    [request] = Decks.pending_requests()
    assert render(view) =~ "✕ image"

    view |> element("button[phx-value-id='#{request["id"]}']", "✕ image") |> render_click()

    assert Decks.pending_requests() == []
    [stored] = Decks.load_requests()
    assert stored["status"] == "canceled"
    refute render(view) =~ "generating"
  end

  test "failed generations surface as a dismissible banner", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    request =
      Decks.queue_request(%{
        "type" => "asset",
        "deck_id" => "demo",
        "slide_id" => "s1",
        "block" => "image",
        "prompt" => "doomed"
      })

    Decks.update_request(request["id"], %{"status" => "failed", "error" => ":timeout"})
    send(view.pid, :queue_updated)

    html = render(view)
    assert html =~ "image failed"
    assert html =~ ":timeout"

    view |> element("button[phx-click='dismiss_failure']") |> render_click()
    refute render(view) =~ "image failed"
  end

  test "escapes hostile text content" do
    hostile = "<script>alert(1)</script> ==<img src=x>=="

    # First line of defense: the validator rejects HTML at the boundary
    assert {:error, [error]} =
             Uitstalling.Decks.parse(%{
               "title" => "x",
               "slides" => [%{"layout" => "statement", "body" => hostile}]
             })

    assert error =~ "HTML tags are not allowed"

    # Second line: even a slide that somehow bypassed validation renders
    # escaped. Build the structs directly to exercise the renderer alone.
    slide = %Uitstalling.Decks.Slide{
      id: "s0",
      layout: "statement",
      tone: "default",
      size: "md",
      fields: %{"body" => hostile}
    }

    deck = %Uitstalling.Decks.Deck{title: "x", accent: "amber", theme: "noir", slides: [slide]}

    html =
      Phoenix.LiveViewTest.render_component(&UitstallingWeb.DeckComponents.slide/1,
        deck: deck,
        slide: slide,
        index: 0
      )

    refute html =~ "<script>alert"
    refute html =~ "<img"
    assert html =~ "&lt;script&gt;"
  end
end
