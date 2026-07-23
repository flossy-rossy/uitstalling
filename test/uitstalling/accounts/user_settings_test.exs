defmodule Uitstalling.Accounts.UserSettingsTest do
  use Uitstalling.DataCase, async: true

  import Uitstalling.Fixtures

  alias Uitstalling.Accounts

  defp custom(label, color), do: %{"label" => label, "color" => color}

  test "defaults are empty and read back as a struct" do
    user = user_fixture()
    settings = Accounts.settings(user)
    assert settings.enabled_element_types == []
    assert settings.custom_element_types == []
  end

  test "enabled is filtered to real curated keys" do
    user = user_fixture()

    {:ok, user} =
      Accounts.update_settings(user, %{
        "enabled_element_types" => ["faction", "nonsense", "character"]
      })

    # "nonsense" dropped, and "character" (a core type, not curated) dropped.
    assert Accounts.settings(user).enabled_element_types == ["faction"]
  end

  test "custom types derive a slug key from the label and keep their color" do
    user = user_fixture()

    {:ok, user} =
      Accounts.update_settings(user, %{"custom_element_types" => [custom("Prophecy", "teal")]})

    assert [%{key: "prophecy", label: "Prophecy", color: "teal"}] =
             Accounts.settings(user).custom_element_types
  end

  test "at most five custom types" do
    user = user_fixture()
    six = for i <- 1..6, do: custom("Kind #{i}", "amber")

    assert {:error, changeset} = Accounts.update_settings(user, %{"custom_element_types" => six})
    assert "at most 5 custom types" in errors_on(changeset).settings.custom_element_types
  end

  test "custom keys must be unique and not shadow a built-in" do
    user = user_fixture()

    assert {:error, cs} =
             Accounts.update_settings(user, %{
               "custom_element_types" => [custom("Spell", "violet"), custom("spell", "rose")]
             })

    assert "custom type names must be unique" in errors_on(cs).settings.custom_element_types

    assert {:error, cs} =
             Accounts.update_settings(user, %{
               "custom_element_types" => [custom("Faction", "rose")]
             })

    assert "that name is already a built-in type" in errors_on(cs).settings.custom_element_types
  end

  test "a color must be a real palette slot; a label must start with a letter" do
    user = user_fixture()

    assert {:error, cs} =
             Accounts.update_settings(user, %{
               "custom_element_types" => [custom("Guild", "chartreuse")]
             })

    assert Map.has_key?(errors_on(cs).settings, :custom_element_types)

    assert {:error, cs} =
             Accounts.update_settings(user, %{"custom_element_types" => [custom("123", "amber")]})

    assert Map.has_key?(errors_on(cs).settings, :custom_element_types)
  end
end
