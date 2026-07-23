defmodule Uitstalling.Accounts.UserSettings.CustomElementType do
  @moduledoc """
  One user-defined plan-element type: a `key` (slug), a display `label`, and a
  colour `slot` chosen from `Uitstalling.Writing.color_slots/0` (so it renders
  through the same Tailwind classes as the built-ins).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Uitstalling.Slug
  alias Uitstalling.Writing

  @primary_key false
  embedded_schema do
    field :key, :string
    field :label, :string
    field :color, :string
  end

  def changeset(custom, attrs) do
    custom
    |> cast(attrs, [:label, :color])
    |> update_change(:label, &String.trim/1)
    |> validate_required([:label, :color])
    |> validate_inclusion(:color, Writing.color_slots())
    |> put_key()
  end

  # The key is derived from the label, never user-supplied — kept slug-shaped
  # (must match Writing's structural element_type check: starts with a letter,
  # [a-z0-9_], ≤32) and stable to reference.
  defp put_key(changeset) do
    with label when is_binary(label) and label != "" <- get_field(changeset, :label),
         slug = Slug.slugify(label) |> String.replace("-", "_") |> String.slice(0, 32),
         true <- slug =~ ~r/^[a-z][a-z0-9_]*$/ do
      put_change(changeset, :key, slug)
    else
      _ -> add_error(changeset, :label, "must start with a letter (a–z)")
    end
  end
end
