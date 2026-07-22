defmodule Uitstalling.Repo.Migrations.CreateWriting do
  use Ecto.Migration

  def change do
    create table(:writing_projects, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      # Content-shaped columns are AES-256-GCM ciphertext under the project
      # DEK; the DEK itself is stored wrapped by the master KEK (kek_id says
      # which ring entry — see Uitstalling.Writing.Vault).
      add :title_enc, :binary, null: false
      add :dek_wrapped, :binary, null: false
      add :kek_id, :string, null: false
      add :theme, :string, null: false, default: "paper"
      add :font, :string, null: false, default: "literata"

      timestamps(type: :utc_datetime)
    end

    create index(:writing_projects, [:user_id])

    create table(:writing_docs, primary_key: false) do
      add :id, :string, primary_key: true

      add :project_id, references(:writing_projects, type: :string, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :position, :integer, null: false, default: 0
      add :title_enc, :binary, null: false
      add :data_enc, :binary, null: false
      # seq of the last applied event — the CAS the write path checks and the
      # cursor the event log appends after.
      add :seq, :integer, null: false, default: 0
      add :word_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:writing_docs, [:project_id])

    create table(:writing_events) do
      add :doc_id, references(:writing_docs, type: :string, on_delete: :delete_all), null: false

      add :seq, :integer, null: false
      add :type, :string, null: false
      add :actor, :string, null: false
      add :source, :string, null: false
      # For type "undo": the seq this event cancels. Plaintext on purpose —
      # the undo walk needs the chain shape without decrypting history.
      add :undoes, :integer
      add :payload_enc, :binary, null: false

      add :inserted_at, :utc_datetime, null: false
    end

    # Per-doc monotonic seq — the unique index IS the optimistic lock: two
    # writers appending after the same snapshot collide here, one loses.
    create unique_index(:writing_events, [:doc_id, :seq])
  end
end
