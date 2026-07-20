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

  test "pdf export runs in the background and hands the browser a one-shot token",
       %{conn: conn} do
    # The demo deck's media slide is an image — no video, no modal
    {:ok, view, _html} = live(conn, "/deck/demo")

    assert render_hook(view, "open_pdf", %{}) =~ "preparing…"
    render_async(view)

    assert_push_event(view, "trigger_download", %{url: "/pdf/" <> token})
    refute render(view) =~ "preparing…"

    # The token serves the file exactly once
    conn = get(build_conn(), "/pdf/#{token}")
    assert response(conn, 200) == "%PDF-1.4 fake"
    assert response_content_type(conn, :pdf)
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"

    assert build_conn() |> get("/pdf/#{token}") |> response(404)
  end

  test "a failed background export surfaces as a dismissible error", %{conn: conn, user: user} do
    Decks.create_deck!(user.id, "pdf-fail-2", %{
      "title" => "Doomed",
      "slides" => [%{"id" => "s0", "layout" => "statement", "body" => "hi"}]
    })

    {:ok, view, _html} = live(conn, "/deck/pdf-fail-2")
    render_hook(view, "open_pdf", %{})
    render_async(view)

    assert render(view) =~ "PDF failed"
    refute render_hook(view, "dismiss_pdf_error", %{}) =~ "PDF failed"
  end

  test "pdf button on a deck with video warns before downloading", %{conn: conn, user: user} do
    Decks.create_deck!(user.id, "vid", %{
      "title" => "Video deck",
      "slides" => [
        %{"id" => "s0", "layout" => "title", "heading" => "Hello"},
        %{
          "id" => "s1",
          "layout" => "media",
          "kind" => "video",
          "src" => "https://example.com/clip.mp4"
        }
      ]
    })

    {:ok, view, _html} = live(conn, "/deck/vid")

    html = render_hook(view, "open_pdf", %{})
    assert html =~ "DOWNLOAD AS PDF"
    assert html =~ "can&#39;t play video"

    refute render_hook(view, "close_pdf", %{}) =~ "DOWNLOAD AS PDF"

    # Confirming starts the background export
    render_hook(view, "open_pdf", %{})
    render_hook(view, "start_pdf", %{})
    render_async(view)
    assert_push_event(view, "trigger_download", %{url: "/pdf/" <> _token})
  end

  test "add_slide inserts a placeholder after the selected slide and opens its editor",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_slide", %{"index" => 0})
    html = render_hook(view, "add_slide", %{})

    slides = deck_on_disk()["slides"]
    assert length(slides) == 12
    assert Enum.at(slides, 1)["body"] =~ "A new point"

    ids = Enum.map(slides, & &1["id"])
    assert ids == Enum.uniq(ids)

    # Dropped straight into the new slide's body editor
    assert html =~ "EDIT SLIDE 2"
    assert html =~ "statement"
  end

  test "a save that lost a race refreshes, keeps the typed text, and succeeds on retry",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_block", %{"index" => 0, "block" => "heading"})

    # Another writer (pipeline / other tab) lands AFTER this session loaded
    behind_our_back = put_in(deck_on_disk(), ["slides", Access.at(0), "kicker"], "SNEAKY EDIT")
    Decks.save!("demo", behind_our_back)

    html = render_hook(view, "save_text", %{"value" => "My new heading"})

    # Conflict surfaced, nothing clobbered, editor still open
    assert html =~ "The deck changed while you edited"
    assert html =~ "SNEAKY EDIT"
    assert html =~ "EDIT SLIDE 1"
    assert get_in(deck_on_disk(), ["slides", Access.at(0), "kicker"]) == "SNEAKY EDIT"

    # Saving again lands on the refreshed rev — both writers' work survives
    render_hook(view, "save_text", %{"value" => "My new heading"})
    slide = hd(deck_on_disk()["slides"])
    assert slide["heading"] == "My new heading"
    assert slide["kicker"] == "SNEAKY EDIT"
  end

  test "an open editor survives a background deck update without losing typed text",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_block", %{"index" => 0, "block" => "heading"})

    # Type without saving…
    view
    |> element(~s(form[phx-submit="save_text"]))
    |> render_change(%{"value" => "half-typed heading"})

    # …then a pipeline result / other-session edit lands
    send(view.pid, :deck_updated)
    html = render(view)

    assert html =~ "EDIT SLIDE 1"
    assert html =~ "half-typed heading"
  end

  test "image regen queues the chosen model and drops unknown ones", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_block", %{"index" => 0, "block" => "image"})

    render_hook(view, "queue_image_gen", %{
      "prompt" => "a clean diagram",
      "model" => "openai/gpt-image-2"
    })

    render_hook(view, "select_block", %{"index" => 0, "block" => "image"})
    render_hook(view, "queue_image_gen", %{"prompt" => "another one", "model" => "evil/model"})

    requests = Enum.filter(Decks.open_requests(), &(&1["type"] == "asset"))
    assert %{"model" => "openai/gpt-image-2"} = Enum.find(requests, &(&1["prompt"] =~ "clean"))
    refute Enum.find(requests, &(&1["prompt"] =~ "another")) |> Map.has_key?("model")
  end

  test "table rows edit cell by cell, preserving tints", %{conn: conn} do
    index = Enum.find_index(deck_on_disk()["slides"], &(&1["layout"] == "table"))
    original_row = deck_on_disk()["slides"] |> Enum.at(index) |> Map.fetch!("rows") |> hd()
    assert Enum.any?(original_row, &match?(%{"tint" => _}, &1))

    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_block", %{"index" => index, "block" => "rows.0"})

    # One field per column
    assert render(view) =~ "cell_0"

    render_hook(view, "save_text", %{
      "cell_0" => "AAA",
      "cell_1" => "BBB",
      "cell_2" => "CCC",
      "cell_3" => "DDD"
    })

    row = deck_on_disk()["slides"] |> Enum.at(index) |> Map.fetch!("rows") |> hd()

    texts =
      Enum.map(row, fn
        %{"text" => t} -> t
        t -> t
      end)

    assert texts == ~w(AAA BBB CCC DDD)
    # Structured cells kept their tints
    assert Enum.count(row, &match?(%{"tint" => _}, &1)) ==
             Enum.count(original_row, &match?(%{"tint" => _}, &1))
  end

  test "table headers edit as one item per line", %{conn: conn} do
    index = Enum.find_index(deck_on_disk()["slides"], &(&1["layout"] == "table"))

    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_block", %{"index" => index, "block" => "columns"})
    render_hook(view, "save_text", %{"value" => "One\nTwo\nThree\nFour"})

    assert deck_on_disk()["slides"] |> Enum.at(index) |> Map.fetch!("columns") ==
             ~w(One Two Three Four)
  end

  test "empty-space clicks open slide options only in edit mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")

    # Not editing: ignored
    render_hook(view, "select_slide_bg", %{"index" => 0})
    refute render(view) =~ "EDIT SLIDE 1"

    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_slide_bg", %{"index" => 0})
    assert render(view) =~ "EDIT SLIDE 1"
  end

  test "image regen sends the current image as reference by default", %{conn: conn} do
    raw =
      put_in(
        deck_on_disk(),
        ["slides", Access.at(0), "image"],
        %{"asset_id" => "ast_0123456789abcdef"}
      )

    Decks.save!("demo", raw)

    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})

    # No use_reference param at all (fresh form) — reference rides along
    render_hook(view, "select_block", %{"index" => 0, "block" => "image"})
    render_hook(view, "queue_image_gen", %{"prompt" => "same but bolder"})

    # Explicitly unticked — no reference
    render_hook(view, "select_block", %{"index" => 0, "block" => "image"})

    render_hook(view, "queue_image_gen", %{
      "prompt" => "something new",
      "use_reference" => "false"
    })

    requests = Enum.filter(Decks.open_requests(), &(&1["type"] == "asset"))

    assert %{"reference_asset_id" => "ast_0123456789abcdef"} =
             Enum.find(requests, &(&1["prompt"] =~ "bolder"))

    refute Enum.find(requests, &(&1["prompt"] =~ "something new"))
           |> Map.has_key?("reference_asset_id")
  end

  test "set_tone recolours one slide only", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_slide", %{"index" => 1})
    render_hook(view, "set_tone", %{"tone" => "accent"})

    slides = deck_on_disk()["slides"]
    assert Enum.at(slides, 1)["tone"] == "accent"
    refute Enum.at(slides, 0)["tone"] == "accent"

    # Junk tones are a no-op
    render_hook(view, "select_slide", %{"index" => 1})
    render_hook(view, "set_tone", %{"tone" => "hotdog"})
    assert Enum.at(deck_on_disk()["slides"], 1)["tone"] == "accent"
  end

  test "saving the image editor persists a crop; reset drops it", %{conn: conn} do
    # An image part references an asset by id shape only — no upload needed
    raw =
      put_in(
        deck_on_disk(),
        ["slides", Access.at(0), "image"],
        %{"asset_id" => "ast_0123456789abcdef"}
      )

    Decks.save!("demo", raw)

    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_block", %{"index" => 0, "block" => "image"})

    render_hook(view, "save_image", %{
      "alt" => "",
      "crop_x" => "30",
      "crop_y" => "62.5",
      "crop_zoom" => "2"
    })

    assert %{"crop" => %{"x" => 30.0, "y" => 62.5, "zoom" => 2.0}} =
             get_in(deck_on_disk(), ["slides", Access.at(0), "image"])

    # Centered zoom-1 is "no crop" — saving it drops the key
    render_hook(view, "select_block", %{"index" => 0, "block" => "image"})

    render_hook(view, "save_image", %{
      "alt" => "",
      "crop_x" => "50",
      "crop_y" => "50",
      "crop_zoom" => "1"
    })

    refute get_in(deck_on_disk(), ["slides", Access.at(0), "image"])
           |> Map.has_key?("crop")
  end

  test "an empty media frame converts to a text slide, keeping its words", %{conn: conn} do
    raw =
      put_in(deck_on_disk(), ["slides", Access.at(1)], %{
        "id" => "s1",
        "layout" => "media",
        "kind" => "image",
        "heading" => "Watch this",
        "caption" => "a demo we never found"
      })

    Decks.save!("demo", raw)

    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_slide", %{"index" => 1})
    render_hook(view, "remove_media_frame", %{})

    slide = Enum.at(deck_on_disk()["slides"], 1)
    assert slide["layout"] == "statement"
    assert slide["body"] == "a demo we never found"
    assert slide["heading"] == "Watch this"
    refute Map.has_key?(slide, "kind")
  end

  test "set_theme restyles in place with the paired accent, undo-able", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    render_hook(view, "set_theme", %{"theme" => "blush"})

    assert deck_on_disk()["theme"] == "blush"
    assert deck_on_disk()["accent"] == "rose"
    # The edit chrome follows the deck accent
    assert render(view) =~ ~s(data-ui-accent="rose")

    # An unknown theme is a no-op
    render_hook(view, "set_theme", %{"theme" => "vantablack"})
    assert deck_on_disk()["theme"] == "blush"

    render_hook(view, "undo", %{})
    assert deck_on_disk()["accent"] == "amber"
  end

  test "regen panel keeps typed changes across re-renders", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    render_hook(view, "open_regen", %{})

    view
    |> form("#regen-form", %{
      "prompt" => "same talk but with more slides please",
      "voice" => "drier",
      "research" => ""
    })
    |> render_change()

    html = render(view)
    assert html =~ "same talk but with more slides please"
    assert html =~ "drier"
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
    refute html =~ "tap any part to edit"

    view |> element("button", "✎ edit") |> render_click()
    assert render(view) =~ "tap any part to edit"

    view |> element("#slide-5 [phx-value-block='code']") |> render_click()
    html = render(view)
    assert html =~ "EDIT SLIDE 6"
    assert html =~ "· code"
    # The direct edit form is pre-filled with the raw mini-markup text
    assert html =~ ~s(phx-submit="save_text")
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
    view |> element("#slide-6 [phx-value-block='rows.0']") |> render_click()

    # Rows edit directly now — the agent form still rides below it
    assert render(view) =~ "cell_0"

    view
    |> element("form[phx-submit='queue_edit']")
    |> render_submit(%{"prompt" => "reword this table in layman's terms"})

    html = render(view)
    assert html =~ "generating"
    assert html =~ "1 generating"

    [request] = Decks.pending_requests()
    assert request["slide_id"] == "s6"
    assert request["block"] == "rows.0"
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

  test "a generated image offers its own prompt back for a regenerate, with no footer",
       %{conn: conn, user: user} do
    {:ok, asset} =
      Uitstalling.Assets.create_generated(user.id, "composed art-directed prompt",
        subject: "a phishing proxy between a user and a bank"
      )

    Decks.save!("demo", Decks.put_block(deck_on_disk(), 1, "image", %{"asset_id" => asset.id}))

    {:ok, view, _html} = live(conn, "/deck/demo")

    # No visible caption under a generated image — the prompt is editor-only
    refute render(view) =~ "figcaption"

    render_hook(view, "toggle_edit", %{})
    render_hook(view, "select_block", %{"index" => 1, "block" => "image"})

    html = render(view)
    assert html =~ "Regenerate image"
    assert html =~ "a phishing proxy between a user and a bank"

    view
    |> form("#image-gen-form", %{"prompt" => "the same proxy, but as a subway map"})
    |> render_submit()

    [request] = Decks.pending_requests()
    assert request["type"] == "asset"
    assert request["prompt"] == "the same proxy, but as a subway map"
  end

  test "regenerate deck pulls up the original brief for editing and queues a create",
       %{conn: conn} do
    seeded =
      Decks.queue_request(%{
        "type" => "create",
        "deck_id" => "demo",
        "theme" => "noir",
        "accent" => "amber",
        "voice" => "sharp and technical",
        "minutes" => 15,
        "target_slides" => 11,
        "prompt" => "phishing-resistant auth for a fintech team",
        "research" => "FIDO2 adoption hit 30% in 2025"
      })

    Decks.update_request(seeded["id"], %{"status" => "done"})

    {:ok, view, _html} = live(conn, "/deck/demo")
    render_hook(view, "toggle_edit", %{})
    view |> element(~s(button[phx-click="open_regen"])) |> render_click()

    # The original brief and research come back editable
    html = render(view)
    assert html =~ "REGENERATE THIS DECK"
    assert html =~ "phishing-resistant auth for a fintech team"
    assert html =~ "FIDO2 adoption hit 30% in 2025"

    view
    |> form("#regen-form", %{
      "prompt" => "the same talk, but for executives",
      "voice" => "boardroom-friendly, zero jargon",
      "research" => ""
    })
    |> render_submit()

    [request] = Decks.pending_requests()
    assert request["type"] == "create"
    assert request["prompt"] == "the same talk, but for executives"
    assert request["theme"] == "noir"
    assert request["voice"] == "boardroom-friendly, zero jargon"
    refute Map.has_key?(request, "research")

    # The create overlay takes over while it generates; undo holds the old deck
    assert render(view) =~ "generating your presentation"
    assert has_element?(view, ~s(button[phx-click="undo"]))
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
