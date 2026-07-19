defmodule Uitstalling.SlugTest do
  use ExUnit.Case, async: true

  alias Uitstalling.Slug

  test "slugifies names and titles" do
    assert Slug.slugify("Sam van der Merwe") == "sam-van-der-merwe"

    assert Slug.slugify("Passwordless / WebAuthn — AST edition") ==
             "passwordless-webauthn-ast-edition"

    assert Slug.slugify("  Ünïcode Náme  ") == "unicode-name"
    assert Slug.slugify("🔥🔥🔥") == ""
  end

  test "unique suffixes on collision and falls back when text slugifies to nothing" do
    taken = fn candidate -> candidate in ["sam", "sam-2"] end
    assert Slug.unique("Sam", "presenter", taken) == "sam-3"
    assert Slug.unique("🔥", "presenter", fn _ -> false end) == "presenter"
  end

  test "reserved route segments are never handed out" do
    assert Slug.unique("New", "presenter", fn _ -> false end) == "new-2"
    assert Slug.unique("Deck", "presenter", fn _ -> false end) == "deck-2"
  end
end
