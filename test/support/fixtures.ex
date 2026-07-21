defmodule Uitstalling.Fixtures do
  @moduledoc "Test helpers for seeding users and decks into the sandbox."

  alias Uitstalling.Accounts
  alias Uitstalling.Decks

  @doc "A registered (authorized) user. Test allowlist is empty = open."
  def user_fixture(attrs \\ %{}) do
    email = attrs[:email] || "user-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(email, attrs[:name] || "Test User")
    user
  end

  @doc "Attach a passkey credential row to a user (no real WebAuthn ceremony)."
  def credential_fixture(user) do
    %Uitstalling.Accounts.WebauthnCredential{}
    |> Uitstalling.Accounts.WebauthnCredential.changeset(%{
      user_id: user.id,
      credential_id: :crypto.strong_rand_bytes(16),
      public_key: %{1 => 2, 3 => -7},
      rp_id: "localhost"
    })
    |> Uitstalling.Repo.insert!()
  end

  @doc "Seed the shipped demo deck under id \"demo\", owned by a fresh author."
  def demo_deck_fixture do
    user = user_fixture()
    raw = Jason.decode!(File.read!(Path.join(File.cwd!(), "priv/decks/demo.json")))
    Decks.create_deck!(user.id, "demo", raw)
    %{user: user, deck_id: "demo", raw: raw}
  end
end
