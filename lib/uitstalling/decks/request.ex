defmodule Uitstalling.Decks.Request do
  @moduledoc """
  DB row for a queued edit/create request. `payload` holds the flat request
  map the pipeline and agent consume; `status`/`error`/`done_at` track its
  lifecycle and double as the per-deck metering ledger.
  """

  use Ecto.Schema

  schema "edit_requests" do
    field :deck_id, :string
    field :type, :string
    field :status, :string, default: "pending"
    field :payload, :map
    field :error, :string
    field :done_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
