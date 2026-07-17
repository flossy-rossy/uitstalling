defmodule Uitstalling.Decks.Stored do
  @moduledoc "DB row for a saved deck: the raw AST map, keyed by short id, owned by a user."

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :binary_id
  schema "decks" do
    field :data, :map
    field :expires_at, :utc_datetime

    belongs_to :user, Uitstalling.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
