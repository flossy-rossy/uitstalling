defmodule Uitstalling.Writing.Doc do
  @moduledoc """
  DB row for one doc (a chapter or a planning sheet): the encrypted body
  snapshot plus the plaintext metadata queries need. `seq` is the last
  applied event's number — the CAS every writer checks (see
  `Uitstalling.Writing.apply_ops/6`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "writing_docs" do
    field :kind, :string
    # For kind "element": which plan element this is (character, faction, …).
    field :element_type, :string
    field :position, :integer, default: 0
    field :title_enc, :binary
    field :data_enc, :binary
    field :seq, :integer, default: 0
    field :word_count, :integer, default: 0

    belongs_to :project, Uitstalling.Writing.Project, type: :string

    timestamps(type: :utc_datetime)
  end
end
