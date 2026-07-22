defmodule Uitstalling.Writing.Event do
  @moduledoc """
  One appended change to a doc — the writing feature's event log
  (docs/writing.md). `(doc_id, seq)` is unique: the index is the optimistic
  lock. The payload (realized ops + their inverse, or the initial doc) is
  ciphertext under the project DEK; type/actor/source/timestamps stay plain
  so timelines can render without decrypting history.
  """

  use Ecto.Schema

  schema "writing_events" do
    field :doc_id, :string
    field :seq, :integer
    field :type, :string
    field :actor, :string
    field :source, :string
    field :undoes, :integer
    field :payload_enc, :binary

    field :inserted_at, :utc_datetime
  end
end
