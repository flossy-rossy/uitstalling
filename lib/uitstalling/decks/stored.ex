defmodule Uitstalling.Decks.Stored do
  @moduledoc "DB row for a saved deck: the raw AST map, keyed by short id, owned by a user."

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :binary_id
  schema "decks" do
    field :data, :map
    field :slug, :string
    field :expires_at, :utc_datetime
    # Optimistic-lock revision (see Decks.save/4) + who wrote last
    field :rev, :integer, default: 0
    field :last_actor, :string

    belongs_to :user, Uitstalling.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
