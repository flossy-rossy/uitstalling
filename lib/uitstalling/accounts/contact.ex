defmodule Uitstalling.Accounts.Contact do
  @moduledoc "A directed user→user contact: `user_id` added `contact_id`."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "contacts" do
    belongs_to :user, Uitstalling.Accounts.User
    belongs_to :contact, Uitstalling.Accounts.User

    field :inserted_at, :utc_datetime
  end
end
