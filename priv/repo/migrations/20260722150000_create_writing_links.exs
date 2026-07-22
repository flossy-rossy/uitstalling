defmodule Uitstalling.Repo.Migrations.CreateWritingLinks do
  use Ecto.Migration

  def change do
    # Plan elements (characters, factions, themes, …) are docs of kind
    # "element" — element_type says which. Plaintext enum, queryable.
    alter table(:writing_docs) do
      add :element_type, :string
    end

    # Links between docs of one project: chapter→element tags and
    # element→element relations, one uniform table. Stored directed,
    # displayed undirected. Pure metadata (titles stay encrypted on the
    # docs); deliberately not event-sourced — linking is shelf-keeping,
    # not writing.
    create table(:writing_links) do
      add :project_id, references(:writing_projects, type: :string, on_delete: :delete_all),
        null: false

      add :source_id, references(:writing_docs, type: :string, on_delete: :delete_all),
        null: false

      add :target_id, references(:writing_docs, type: :string, on_delete: :delete_all),
        null: false

      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:writing_links, [:source_id, :target_id])
    create index(:writing_links, [:target_id])
    create index(:writing_links, [:project_id])
  end
end
