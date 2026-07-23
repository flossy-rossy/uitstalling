defmodule Uitstalling.Accounts.ContactsTest do
  use Uitstalling.DataCase, async: true

  import Uitstalling.Fixtures

  alias Uitstalling.Accounts

  test "add by email, list, and remove" do
    me = user_fixture(name: "Me")
    them = user_fixture(email: "them@example.com", name: "Them")

    assert {:ok, %{id: their_id}} = Accounts.add_contact(me, "them@example.com")

    assert [%{id: ^their_id, name: "Them", email: "them@example.com"}] =
             Accounts.list_contacts(me)

    # It's directed — they don't have me back.
    assert Accounts.list_contacts(them) == []

    assert :ok = Accounts.remove_contact(me, their_id)
    assert Accounts.list_contacts(me) == []
  end

  test "adding is idempotent (case-insensitive email), one row per pair" do
    me = user_fixture()
    _them = user_fixture(email: "them@example.com")

    assert {:ok, _} = Accounts.add_contact(me, "them@example.com")
    assert {:ok, _} = Accounts.add_contact(me, "THEM@example.com")
    assert length(Accounts.list_contacts(me)) == 1
  end

  test "unknown email and self are refused" do
    me = user_fixture(email: "me@example.com")

    assert {:error, :not_found} = Accounts.add_contact(me, "nobody@example.com")
    assert {:error, :self} = Accounts.add_contact(me, "me@example.com")
    assert Accounts.list_contacts(me) == []
  end
end
