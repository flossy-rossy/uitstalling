defmodule UitstallingWeb.UserLiveTest do
  # async: false — mutates the shared demo deck's slug
  use UitstallingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Uitstalling.Accounts
  alias Uitstalling.Decks

  setup do
    %{user: user} = Uitstalling.Fixtures.demo_deck_fixture()
    %{user: Accounts.ensure_slug!(user)}
  end

  test "the public page lists a presenter's decks with no edit affordances", %{user: user} do
    {:ok, _view, html} = live(build_conn(), "/#{user.slug}")

    assert html =~ user.name
    assert html =~ "Passwordless / WebAuthn"
    assert html =~ "11 slides"
    assert html =~ "remote"
    refute html =~ "✎ edit"
    refute html =~ "New presentation"
  end

  test "slugged deck and remote URLs render, and the raw id still works", %{user: user} do
    # First public view mints the deck slug from its title
    {:ok, _view, _html} = live(build_conn(), "/#{user.slug}")
    slug = Decks.deck_slug("demo")
    assert slug =~ "passwordless"

    {:ok, _view, deck_html} = live(build_conn(), "/#{user.slug}/#{slug}")
    assert deck_html =~ "Phishing in 2026."
    assert deck_html =~ "/#{user.slug}/#{slug}/remote"

    {:ok, _view, remote_html} = live(build_conn(), "/#{user.slug}/#{slug}/remote")
    assert remote_html =~ "REMOTE"

    # Pre-slug style: raw deck id in the slug position keeps working
    {:ok, _view, by_id} = live(build_conn(), "/#{user.slug}/demo")
    assert by_id =~ "Phishing in 2026."
  end

  test "unknown slugs bounce home with a flash" do
    assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), "/nobody-here")
    assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), "/nobody-here/no-deck")
  end

  test "another presenter's slug can't reach someone else's deck", %{user: user} do
    other = Accounts.invite_user("other@example.com", "Other Person")

    # The demo deck belongs to `user`, not `other` — no cross-tenant access
    {:ok, _view, _html} = live(build_conn(), "/#{user.slug}")

    assert {:error, {:redirect, %{to: "/"}}} =
             live(build_conn(), "/#{other.slug}/demo")
  end
end
