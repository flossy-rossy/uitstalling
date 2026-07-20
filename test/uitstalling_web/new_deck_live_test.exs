defmodule UitstallingWeb.NewDeckLiveTest do
  use UitstallingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user = Uitstalling.Fixtures.user_fixture()
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    %{conn: conn, user: user}
  end

  # Regression: inputs must render from server-held form state — with the
  # old no-op validate, the first unrelated re-render (upload progress,
  # research error) reset everything already typed.
  test "typed values survive re-renders", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/new")

    view
    |> form("#create-form", %{
      "theme" => "midnight",
      "voice" => "sharp and short",
      "minutes" => "20",
      "prompt" => "why passkeys beat TOTP"
    })
    |> render_change()

    html = render(view)
    assert html =~ "sharp and short"
    assert html =~ "why passkeys beat TOTP"
    assert has_element?(view, ~s(input[name="theme"][value="midnight"][checked]))
    refute has_element?(view, ~s(input[name="theme"][value="noir"][checked]))
    assert has_element?(view, ~s(#create-form option[value="20"][selected]))
  end

  test "create uses the picked theme with its paired accent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/new")

    view
    |> form("#create-form", %{
      "theme" => "pistachio",
      "minutes" => "10",
      "voice" => "",
      "prompt" => "a pastel talk"
    })
    |> render_submit()

    {path, _flash} = assert_redirect(view)
    "/deck/" <> deck_id = path

    raw = Uitstalling.Decks.load_raw!(deck_id)
    assert raw["theme"] == "pistachio"
    assert raw["accent"] == "emerald"
  end

  test "an unauthorized visitor is sent to login" do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(build_conn(), "/new")
  end
end
