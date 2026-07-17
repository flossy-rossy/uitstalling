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

  test "an unauthenticated visitor sees the sign-in CTA, not authoring", %{conn: _conn} do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Sign in"
    assert html =~ "closed beta"
    refute html =~ "New presentation"
  end

  test "/new redirects unauthenticated visitors to login", %{conn: _conn} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(build_conn(), "/new")
  end

  test "home lists decks with links to present", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "New presentation"
    assert html =~ "Passwordless / WebAuthn"
    assert html =~ "/deck/demo"
  end

  test "the new-presentation form generates a deck end to end", %{conn: conn} do
    start_supervised!(Decks.Pipeline)

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

    # The pipeline (fake agent) replaces it with the generated deck and marks
    # the request done (status flips just after the deck is saved).
    assert_eventually(fn ->
      Decks.load_raw!(deck_id)["title"] == "FAKE DECK: the story of our product" and
        match?([%{"status" => "done"}], Decks.load_requests())
    end)

    [request] = Decks.load_requests()
    assert request["target_slides"] == 11
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
