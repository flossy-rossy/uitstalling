defmodule Uitstalling.Writing.Link do
  @moduledoc """
  A directed link between two docs of one project — chapter→element tags and
  element→element relations share this table (displayed undirected). Pure
  metadata: the linked docs' titles stay encrypted on their own rows.
  """

  use Ecto.Schema

  schema "writing_links" do
    field :project_id, :string
    field :source_id, :string
    field :target_id, :string

    field :inserted_at, :utc_datetime
  end
end
