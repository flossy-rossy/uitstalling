defmodule Uitstalling.Repo.Migrations.WritingImagesAndTypes do
  use Ecto.Migration

  def up do
    # Portraits/sketches for plan elements. NOT the public assets bucket on
    # purpose: writing is private, so image bytes are AES-256-GCM ciphertext
    # under the project DEK, served only through an owner-authenticated route.
    create table(:writing_images, primary_key: false) do
      add :id, :string, primary_key: true

      add :project_id, references(:writing_projects, type: :string, on_delete: :delete_all),
        null: false

      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :data_enc, :binary, null: false

      add :inserted_at, :utc_datetime, null: false
    end

    create index(:writing_images, [:project_id])

    # "object" reads better than "item" for story things.
    execute "UPDATE writing_docs SET element_type = 'object' WHERE element_type = 'item'"
  end

  def down do
    execute "UPDATE writing_docs SET element_type = 'item' WHERE element_type = 'object'"
    drop table(:writing_images)
  end
end
