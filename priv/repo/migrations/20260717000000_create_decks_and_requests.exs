defmodule Uitstalling.Repo.Migrations.CreateDecksAndRequests do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # nil until the anonymous user registers (passkey / magic-link / Google)
      add :email, :string
      add :name, :string
      add :anonymous, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email], where: "email is not null")

    create table(:decks, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :data, :map, null: false
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:decks, [:user_id])
    create index(:decks, [:expires_at])

    create table(:edit_requests) do
      add :deck_id, :string, null: false
      add :type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :payload, :map, null: false
      add :error, :text
      add :done_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:edit_requests, [:deck_id])
    create index(:edit_requests, [:status])
  end
end
