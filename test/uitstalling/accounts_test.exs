defmodule Uitstalling.AccountsTest do
  use Uitstalling.DataCase, async: false

  import Uitstalling.Fixtures, only: [user_fixture: 0, credential_fixture: 1]

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

    # An abandoned first ceremony (no passkey yet) may simply retry
    assert {:ok, retry} = Accounts.register_user("anyone@example.com")
    assert retry.id == user.id
  end

  test "registering a passkey consumes the invite; another passkey needs a fresh invite" do
    Accounts.invite_user("friend@example.com", "Sam")
    assert %{} = Accounts.unclaimed_invite("friend@example.com")

    {:ok, user} = Accounts.register_user("friend@example.com")
    credential_fixture(user)
    Accounts.claim_invites(user)

    assert Accounts.unclaimed_invite("friend@example.com") == nil
    refute Accounts.may_register_credential?(user)
    assert {:error, :invite_required} = Accounts.register_user("friend@example.com")

    # Recovery = re-invite: reopens registration for the same account
    Accounts.invite_user("friend@example.com", "Sam")
    assert Accounts.may_register_credential?(user)
    assert {:ok, again} = Accounts.register_user("friend@example.com")
    assert again.id == user.id
  end

  test "knowing a registered email is not enough to add a passkey, even in open mode" do
    user = user_fixture()
    credential_fixture(user)

    refute Accounts.may_register_credential?(user)
    assert {:error, :invite_required} = Accounts.register_user(user.email)
  end

  test "re-inviting never stacks a second live invite" do
    Accounts.invite_user("friend@example.com", "Sam")
    Accounts.invite_user("friend@example.com", "Samantha")

    assert Repo.aggregate(Uitstalling.Accounts.Invite, :count) == 1
  end
end
