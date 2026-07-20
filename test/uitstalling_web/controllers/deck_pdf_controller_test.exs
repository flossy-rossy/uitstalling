defmodule UitstallingWeb.DeckPdfControllerTest do
  use UitstallingWeb.ConnCase, async: false

  alias Uitstalling.Decks

  @video_deck %{
    "title" => "Video deck",
    "accent" => "amber",
    "slides" => [
      %{"id" => "s0", "layout" => "title", "heading" => "Hello"},
      %{
        "id" => "s1",
        "layout" => "media",
        "kind" => "video",
        "src" => "https://example.com/clip.mp4",
        "caption" => "the demo"
      }
    ]
  }

  setup do
    %{user: user} = Uitstalling.Fixtures.demo_deck_fixture()
    %{user: user}
  end

  describe "GET /deck/:id/print" do
    test "renders every slide as a dead page", %{conn: conn} do
      conn = get(conn, "/deck/demo/print")
      html = html_response(conn, 200)

      # First and last slides of the demo deck are both on the one page
      assert html =~ "TOTP isn&#39;t saving you."
      assert html =~ "Phishing in 2026."
      # Dead render: no LiveView plumbing, page geometry comes from the view
      refute html =~ "phx-hook"
      assert html =~ "13.333in"
    end

    test "video degrades to a placeholder card, never a <video>", %{user: user} do
      Decks.create_deck!(user.id, "vid", @video_deck)
      html = build_conn() |> get("/deck/vid/print") |> html_response(200)

      refute html =~ "<video"
      assert html =~ "plays in the live presentation"
      assert html =~ "https://example.com/clip.mp4"
    end

    test "404s for unknown decks" do
      assert build_conn() |> get("/deck/nope/print") |> response(404)
    end
  end

  describe "GET /deck/:id/pdf" do
    test "sends the rendered PDF as a named attachment", %{conn: conn} do
      conn = get(conn, "/deck/demo/pdf")

      assert response(conn, 200) == "%PDF-1.4 fake"
      assert response_content_type(conn, :pdf)
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ~s(.pdf")
    end

    test "a failed print degrades to a flash on the deck, not a 500", %{user: user} do
      Decks.create_deck!(user.id, "pdf-fail-1", @video_deck)
      conn = get(build_conn(), "/deck/pdf-fail-1/pdf")

      assert redirected_to(conn) == "/deck/pdf-fail-1"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Couldn't produce the PDF"
    end

    test "404s for unknown decks" do
      assert build_conn() |> get("/deck/nope/pdf") |> response(404)
    end
  end
end
