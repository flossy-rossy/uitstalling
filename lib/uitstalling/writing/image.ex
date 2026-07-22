defmodule Uitstalling.Writing.Image do
  @moduledoc """
  DB row for a writing image (a character portrait, a sketch): ciphertext
  under the project DEK, deliberately separate from the public `assets`
  bucket. Served only via the owner-authenticated writing image route.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "writing_images" do
    field :content_type, :string
    field :byte_size, :integer
    field :data_enc, :binary

    belongs_to :project, Uitstalling.Writing.Project, type: :string

    field :inserted_at, :utc_datetime
  end
end
