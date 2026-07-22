defmodule Uitstalling.Writing.Project do
  @moduledoc """
  DB row for a writing project (one novel/work): owner, theme, font, and the
  wrapped DEK everything under the project is encrypted with. The title is
  ciphertext — decrypt through `Uitstalling.Writing`, never read it raw.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :binary_id
  schema "writing_projects" do
    field :title_enc, :binary
    field :dek_wrapped, :binary
    field :kek_id, :string
    field :theme, :string, default: "paper"
    field :font, :string, default: "literata"

    belongs_to :user, Uitstalling.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
