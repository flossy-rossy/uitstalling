defmodule Uitstalling.Accounts.WebauthnCredential do
  @moduledoc "A registered WebAuthn / passkey credential belonging to a user."

  use Ecto.Schema
  import Ecto.Changeset

  alias Uitstalling.Accounts.{CoseKey, User}

  @foreign_key_type :binary_id

  schema "webauthn_credentials" do
    field :credential_id, :binary
    field :public_key, CoseKey
    field :sign_count, :integer, default: 0
    field :rp_id, :string
    field :label, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @required [:credential_id, :public_key, :rp_id, :user_id]
  @optional [:sign_count, :label, :last_used_at]

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:label, max: 160)
    |> unique_constraint(:credential_id)
    |> foreign_key_constraint(:user_id)
  end
end
