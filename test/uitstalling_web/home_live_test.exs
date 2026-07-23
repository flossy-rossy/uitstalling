defmodule UitstallingWeb.HomeLiveTest do
  # async: false — the create flow mutates the shared decks dir + queue
  use UitstallingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Uitstalling.Decks

  setup %{conn: conn} do
    %{user: user} = Uitstalling.Fixtures.demo_deck_fixture()
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    %{conn: conn, user: user}
  end

  test "the front door offers the two modes", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "What are we making today?" or html =~ "what are we making today?"
    assert html =~ ~s(href="/write")
    assert html =~ ~s(href="/decks")
  end

  test "an unauthenticated visitor sees the sign-in CTA, not authoring", %{conn: _conn} do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "sign in"
    assert html =~ "closed beta"
    refute html =~ "New presentation"

    {:ok, _view, decks_html} = live(build_conn(), "/decks")
    assert decks_html =~ "Sign in"
    assert decks_html =~ "closed beta"
    refute decks_html =~ "New presentation"
  end

  test "/new redirects unauthenticated visitors to login", %{conn: _conn} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(build_conn(), "/new")
  end

  test "a fresh invitee gets the personal welcome splash until their first deck", %{conn: _} do
    invited = Uitstalling.Accounts.invite_user("fresh@example.com", "Sam Marais")
    conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => invited.id})

    {:ok, _view, html} = live(conn, "/decks")
    assert html =~ "Welcome"
    assert html =~ "Sam"
    assert html =~ "get you presenting"
    refute html =~ "Describe your talk."
  end

  test "an uploaded research document lands in the create request", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/new")

    xml =
      ~s(<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>) <>
        "<w:p><w:r><w:t>WebAuthn shipped in Chrome 67 and covers 99% of users.</w:t></w:r></w:p>" <>
        "</w:body></w:document>"

    {:ok, {_name, docx}} =
      :zip.create(~c"mem.zip", [{~c"word/document.xml", xml}], [:memory])

    research =
      file_input(view, "#create-form", :research, [
        %{
          name: "sources.docx",
          content: docx,
          type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        }
      ])

    render_upload(research, "sources.docx")

    {:error, {:live_redirect, %{to: "/deck/" <> _deck_id}}} =
      view
      |> element("#create-form")
      |> render_submit(%{
        "theme" => "noir",
        "voice" => "friendly",
        "minutes" => "10",
        "prompt" => "why passkeys beat passwords"
      })

    [request] = Decks.pending_requests()
    assert request["research"] =~ "Chrome 67"
    assert request["research_filename"] == "sources.docx"
  end

  test "/decks lists decks with links to present", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/decks")

    assert html =~ "New presentation"
    assert html =~ "Passwordless / WebAuthn"
    assert html =~ "/deck/demo"
  end

  test "the new-presentation form generates a deck end to end", %{conn: conn} do
    {:ok, view, html} = live(conn, "/new")
    assert html =~ "THEME"
    assert html =~ "TONE &amp; AUDIENCE"

    {:error, {:live_redirect, %{to: "/deck/" <> deck_id}}} =
      view
      |> element("form")
      |> render_submit(%{
        "theme" => "midnight",
        "voice" => "friendly crowd",
        "minutes" => "15",
        "prompt" => "the story of our product"
      })

    # The stub exists immediately, enforced with the form's choices
    raw = Decks.load_raw!(deck_id)
    assert raw["theme"] == "midnight"
    assert raw["accent"] == "cyan"

    # This deck's worker (only startable once the deck id exists) boot-drains
    # the queued create; the fake agent replaces the stub and marks the
    # request done (status flips just after the deck is saved).
    start_supervised!({Decks.DeckWorker, deck_id})

    # The create finishes, then the title-slide image it requested.
    assert_eventually(fn ->
      Decks.load_raw!(deck_id)["title"] == "FAKE DECK: the story of our product" and
        Enum.all?(Decks.load_requests(), &(&1["status"] == "done"))
    end)

    [request, image_request] = Decks.load_requests()
    assert request["target_slides"] == 11
    assert image_request["type"] == "asset"
    assert %{"asset_id" => _} = hd(Decks.load_raw!(deck_id)["slides"])["image"]
  end

  test "visiting a missing deck redirects home", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/deck/nope")
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
end
