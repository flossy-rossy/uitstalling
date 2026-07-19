defmodule Uitstalling.Repo.Migrations.AddSlugs do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :slug, :string
    end

    create unique_index(:users, [:slug])

    alter table(:decks) do
      add :slug, :string
    end

    # Deck slugs are unique per owner — two people can both have "quarterly-update"
    create unique_index(:decks, [:user_id, :slug])
  end
end
