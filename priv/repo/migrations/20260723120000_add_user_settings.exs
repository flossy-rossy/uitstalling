defmodule Uitstalling.Repo.Migrations.AddUserSettings do
  use Ecto.Migration

  def change do
    # Per-user settings blob (embeds_one on the User schema): enabled curated
    # element types + custom types today, room for other per-user prefs later.
    # Absent = defaults, so existing rows need no backfill.
    alter table(:users) do
      add :settings, :map, default: %{}
    end
  end
end
