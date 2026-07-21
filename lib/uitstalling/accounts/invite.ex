defmodule Uitstalling.Accounts.Invite do
  @moduledoc """
  A single-use authorization to register a passkey for an email address.

  Creating a passkey claims the invite (`claimed_at`/`claimed_by`), so an
  account can never grow extra passkeys just by re-running signup — losing a
  passkey means asking for a fresh invite. The same claim mechanic is the seam
  for a future self-service recovery flow (an email OTP would mint the invite
  instead of an admin).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "invites" do
    field :email, :string
    field :name, :string
    field :claimed_at, :utc_datetime

    belongs_to :claimed_by, Uitstalling.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
