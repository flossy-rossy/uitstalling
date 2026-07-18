defmodule Uitstalling.Repo.Migrations.CreateAssets do
  use Ecto.Migration

  def change do
    create table(:assets, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :kind, :string, null: false, default: "image"
      add :origin, :string, null: false
      add :provider, :string
      add :prompt, :text
      add :source_url, :text
      add :storage_key, :string
      add :content_type, :string
      add :byte_size, :integer
      add :width, :integer
      add :height, :integer
      add :license, :string
      add :attribution, :map
      add :status, :string, null: false, default: "ready"

      timestamps(type: :utc_datetime)
    end

    create index(:assets, [:user_id])
  end
end
