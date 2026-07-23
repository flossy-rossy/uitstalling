defmodule Uitstalling.Repo.Migrations.CreateContacts do
  use Ecto.Migration

  def change do
    # Directed user→user contacts: "I added you." The seam sharing will build
    # on (share a doc with a contact). One row per (owner, contact) pair.
    create table(:contacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :contact_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:contacts, [:user_id, :contact_id])
    create index(:contacts, [:contact_id])
  end
end
