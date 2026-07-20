defmodule Uitstalling.Repo.Migrations.AddRevToDecks do
  use Ecto.Migration

  # Optimistic-lock revision + who wrote last. `rev` is the CAS counter every
  # conditional save checks and bumps; it is also the future event-log seq
  # (docs/event-log-plan.md), so nothing here is throwaway. `last_actor` is a
  # user id or "pipeline" — conflict messages and "last edited by" come free.
  def change do
    alter table(:decks) do
      add :rev, :integer, null: false, default: 0
      add :last_actor, :string
    end
  end
end
