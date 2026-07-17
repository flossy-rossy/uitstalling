defmodule Uitstalling.DecksTest do
  use Uitstalling.DataCase, async: true

  alias Uitstalling.Decks
  alias Uitstalling.Decks.{Deck, Slide}

  setup do
    Uitstalling.Fixtures.demo_deck_fixture()
    :ok
  end

  defp minimal(slide_overrides) do
    %{
      "title" => "Test deck",
      "slides" => [Map.merge(%{"layout" => "statement", "body" => "hello"}, slide_overrides)]
    }
  end

  test "the shipped demo deck parses" do
    assert %Deck{accent: "amber", slides: slides} = Decks.deck!("demo")
    assert length(slides) == 11
    assert %Slide{layout: "title", fields: %{"heading" => _}} = hd(slides)
  end

  test "rejects unknown layouts with a helpful message" do
    assert {:error, [error]} = Decks.parse(minimal(%{"layout" => "hero_banner"}))
    assert error =~ "slides[0].layout"
    assert error =~ "must be one of:"
  end

  test "rejects keys outside the layout's spec" do
    assert {:error, [error]} =
             Decks.parse(minimal(%{"style" => "color: red", "onclick" => "x()"}))

    assert error =~ ~s(unknown keys)
    assert error =~ "onclick"
  end

  test "rejects off-palette colours" do
    deck =
      minimal(%{
        "layout" => "flow",
        "body" => nil,
        "steps" => [%{"actor" => "A", "body" => "b", "color" => "#ff0000"}]
      })
      |> update_in(["slides", Access.at(0)], &Map.delete(&1, "body"))

    assert {:error, errors} = Decks.parse(deck)
    assert Enum.any?(errors, &(&1 =~ "color"))
  end

  test "rejects javascript: and protocol-relative media sources" do
    for src <- ["javascript:alert(1)", "//evil.example/x.png", "http://insecure.example/x.png"] do
      deck = minimal(%{"layout" => "media", "kind" => "image", "src" => src})
      deck = update_in(deck, ["slides", Access.at(0)], &Map.delete(&1, "body"))

      assert {:error, errors} = Decks.parse(deck), "expected #{src} to be rejected"
      assert Enum.any?(errors, &(&1 =~ ".src")), "expected a src error for #{src}"
    end
  end

  test "accepts https, an existing local asset, and an omitted src" do
    # /robots.txt is generated into priv/static by phx.new
    for slide <- [
          %{"layout" => "media", "kind" => "image", "src" => "https://example.com/x.png"},
          %{"layout" => "media", "kind" => "image", "src" => "/robots.txt"},
          %{"layout" => "media", "kind" => "image", "caption" => "a photo of an ear"}
        ] do
      deck = minimal(slide)
      deck = update_in(deck, ["slides", Access.at(0)], &Map.delete(&1, "body"))

      assert {:ok, _} = Decks.parse(deck), "expected #{inspect(slide)} to be accepted"
    end
  end

  test "rejects a local media src that does not exist (the hallucinated-path hole)" do
    deck = minimal(%{"layout" => "media", "kind" => "image", "src" => "/images/ear-care.jpg"})
    deck = update_in(deck, ["slides", Access.at(0)], &Map.delete(&1, "body"))

    assert {:error, errors} = Decks.parse(deck)
    assert Enum.any?(errors, &(&1 =~ "does not exist"))
  end

  test "rejects table rows that don't match the column count" do
    deck =
      minimal(%{
        "layout" => "table",
        "columns" => ["A", "B"],
        "rows" => [["only one cell"]]
      })

    deck = update_in(deck, ["slides", Access.at(0)], &Map.delete(&1, "body"))

    assert {:error, errors} = Decks.parse(deck)
    assert Enum.any?(errors, &(&1 =~ "1 cells but the table has 2 columns"))
  end

  test "error paths point at the exact offending element" do
    deck = %{
      "title" => "Test",
      "slides" => [
        %{"layout" => "statement", "body" => "fine"},
        %{"layout" => "points", "heading" => "h", "points" => [%{"label" => "only label"}]}
      ]
    }

    assert {:error, [error]} = Decks.parse(deck)
    assert error =~ "slides[1].points[0].body"
  end
end
