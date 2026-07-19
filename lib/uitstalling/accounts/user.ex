defmodule Uitstalling.Accounts.User do
  @moduledoc """
  An account. Created anonymously on first visit (`anonymous: true`, no email);
  `email`/`name` fill in when the user registers. Auth credentials (passkeys,
  magic-link tokens, Google identities) attach in their own tables later,
  keyed to this row — so an anonymous user's decks survive when they claim
  the account.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :name, :string
    field :slug, :string
    field :anonymous, :boolean, default: true

    has_many :decks, Uitstalling.Decks.Stored

    timestamps(type: :utc_datetime)
  end
end
