defmodule Uitstalling.Repo.Migrations.CreateInvites do
  use Ecto.Migration

  def up do
    create table(:invites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :name, :string
      add :claimed_at, :utc_datetime
      add :claimed_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:invites, [:email])

    # At most one live invite per email — claiming is an UPDATE .. WHERE
    # claimed_at IS NULL, so a single row is the whole race surface.
    create unique_index(:invites, [:email],
             where: "claimed_at IS NULL",
             name: :invites_unclaimed_email_index
           )

    # Everyone invited before this table existed (a user row with no passkey
    # yet) keeps a pending invite, so the new "a passkey consumes an invite"
    # rule can't lock them out of finishing signup.
    execute """
    INSERT INTO invites (id, email, name, inserted_at, updated_at)
    SELECT gen_random_uuid(), u.email, u.name, now(), now()
    FROM users u
    WHERE u.email IS NOT NULL
      AND u.anonymous = false
      AND NOT EXISTS (
        SELECT 1 FROM webauthn_credentials c WHERE c.user_id = u.id
      )
    """
  end

  def down do
    drop table(:invites)
  end
end
