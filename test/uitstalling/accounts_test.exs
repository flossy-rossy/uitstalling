defmodule Uitstalling.AccountsTest do
  use Uitstalling.DataCase, async: false

  alias Uitstalling.Accounts

  # The test allowlist is empty (= open); pin a closed one per test.
  defp with_allowlist(emails) do
    previous = Application.get_env(:uitstalling, :allowed_emails, [])
    Application.put_env(:uitstalling, :allowed_emails, emails)
    on_exit(fn -> Application.put_env(:uitstalling, :allowed_emails, previous) end)
  end

  test "an invited user can register despite a closed allowlist, keeping their invite name" do
    with_allowlist(["only-the-owner@example.com"])

    invited = Accounts.invite_user("Friend@Example.com  ", "Sam Marais")
    assert invited.email == "friend@example.com"
    assert invited.name == "Sam Marais"
    assert Accounts.can_author?(invited)

    # Registration finds the invite — signup sends no name, the invite's stays
    assert {:ok, user} = Accounts.register_user("friend@example.com")
    assert user.id == invited.id
    assert user.name == "Sam Marais"

    # A stranger is still blocked by the allowlist
    assert {:error, :not_allowed} = Accounts.register_user("stranger@example.com")
  end

  test "re-inviting an existing email just updates the name" do
    first = Accounts.invite_user("friend@example.com", "Sam")
    second = Accounts.invite_user("friend@example.com", "Samantha")

    assert second.id == first.id
    assert second.name == "Samantha"
  end

  test "open allowlist registration works without a name" do
    assert {:ok, user} = Accounts.register_user("anyone@example.com")
    assert user.name == nil
    assert Accounts.can_author?(user)
  end
end
