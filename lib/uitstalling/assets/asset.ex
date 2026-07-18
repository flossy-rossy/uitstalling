defmodule Uitstalling.Assets.Asset do
  @moduledoc """
  DB row for a stored visual asset. Decks reference assets by id
  (`{"image": {"asset_id": "ast_..."}}`) — never by URL or file path — so the
  text model can't hallucinate sources and storage can move without touching
  deck JSON. `origin` records how the asset came to exist (upload | stock |
  gen); stock/gen columns (provider, prompt, source_url, license,
  attribution) are populated by the phase-2 asset pipeline.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :binary_id
  schema "assets" do
    field :kind, :string, default: "image"
    field :origin, :string
    field :provider, :string
    field :prompt, :string
    field :source_url, :string
    field :storage_key, :string
    field :content_type, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :license, :string
    field :attribution, :map
    field :status, :string, default: "ready"

    belongs_to :user, Uitstalling.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
