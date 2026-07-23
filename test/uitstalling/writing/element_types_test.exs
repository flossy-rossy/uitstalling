defmodule Uitstalling.Writing.ElementTypesTest do
  use Uitstalling.DataCase, async: true

  import Uitstalling.Fixtures

  alias Uitstalling.Accounts
  alias Uitstalling.Writing

  describe "active_element_types/1" do
    test "a fresh user gets core only" do
      user = user_fixture()
      keys = Enum.map(Writing.active_element_types(user), & &1.key)
      assert keys == Writing.core_element_types()
    end

    test "core + enabled curated + custom, in that order" do
      user = user_fixture()

      {:ok, user} =
        Accounts.update_settings(user, %{
          "enabled_element_types" => ["faction", "theme"],
          "custom_element_types" => [%{"label" => "Spell", "color" => "violet"}]
        })

      types = Writing.active_element_types(user)
      keys = Enum.map(types, & &1.key)

      assert keys == Writing.core_element_types() ++ ["faction", "theme", "spell"]
      assert %{key: "spell", label: "Spell", color: "violet"} = List.last(types)
    end
  end

  describe "element_type_registry/1" do
    test "covers every built-in (even not-enabled), the customs, and kind fallbacks" do
      user = user_fixture()

      {:ok, user} =
        Accounts.update_settings(user, %{
          "custom_element_types" => [%{"label" => "Spell", "color" => "violet"}]
        })

      reg = Writing.element_type_registry(user)

      # Built-in with its designed colour, even though the user never enabled it.
      assert %{color: "rose"} = reg["faction"]
      # Custom type.
      assert %{label: "Spell", color: "violet"} = reg["spell"]
      # Doc-kind fallbacks so chapters/plan-maps render a chip too.
      assert %{color: "stone"} = reg["chapter"]
      assert %{color: "slate"} = reg["planning"]
    end
  end

  describe "check_element_type (structural, via create_element)" do
    setup do
      %{project: project} = writing_project_fixture()
      %{project: project}
    end

    test "accepts a slug-shaped custom type", %{project: project} do
      assert {:ok, _} = Writing.create_element(project, "spell", "Fireball")
    end

    test "rejects non-slug and over-long types", %{project: project} do
      assert {:error, ["element_type: invalid"]} =
               Writing.create_element(project, "Not Slug", "x")

      assert {:error, ["element_type: invalid"]} = Writing.create_element(project, "1bad", "x")
      long = String.duplicate("a", 33)
      assert {:error, ["element_type: required"]} = Writing.create_element(project, long, "x")
    end
  end
end
