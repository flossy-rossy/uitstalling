defmodule Uitstalling.Accounts.UserSettings do
  @moduledoc """
  Per-user settings, embedded in the `users.settings` map column — the general
  home for small per-user preferences and opt-ins. Its first tenant is the
  writing plan-element customization: which curated element types the user has
  turned on, and their own custom types (see docs/writing.md). Absent settings
  read back as this struct's defaults, so existing users need no backfill.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Uitstalling.Accounts.UserSettings.CustomElementType
  alias Uitstalling.Writing

  @primary_key false
  embedded_schema do
    # Curated element types the user opted into (core types are always on).
    field :enabled_element_types, {:array, :string}, default: []
    embeds_many :custom_element_types, CustomElementType, on_replace: :delete
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:enabled_element_types])
    |> cast_embed(:custom_element_types)
    |> validate_enabled()
    |> validate_custom()
  end

  # Only real curated keys can be enabled (silently drop anything else, so a
  # stale checkbox can't wedge a save).
  defp validate_enabled(changeset) do
    case get_change(changeset, :enabled_element_types) do
      nil ->
        changeset

      list ->
        curated = MapSet.new(Writing.curated_element_types())

        put_change(
          changeset,
          :enabled_element_types,
          Enum.filter(list, &MapSet.member?(curated, &1))
        )
    end
  end

  defp validate_custom(changeset) do
    customs = get_field(changeset, :custom_element_types)
    keys = Enum.map(customs, & &1.key)
    builtins = MapSet.new(Writing.builtin_element_types())

    cond do
      length(customs) > Writing.max_custom_types() ->
        add_error(
          changeset,
          :custom_element_types,
          "at most #{Writing.max_custom_types()} custom types"
        )

      keys != Enum.uniq(keys) ->
        add_error(changeset, :custom_element_types, "custom type names must be unique")

      Enum.any?(keys, &MapSet.member?(builtins, &1)) ->
        add_error(changeset, :custom_element_types, "that name is already a built-in type")

      true ->
        changeset
    end
  end
end
