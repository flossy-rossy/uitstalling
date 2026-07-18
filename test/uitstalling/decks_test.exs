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

  test "rejects duplicate slide ids" do
    deck = %{
      "title" => "Test",
      "slides" => [
        %{"id" => "s0", "layout" => "statement", "body" => "one"},
        %{"id" => "s0", "layout" => "statement", "body" => "two"}
      ]
    }

    assert {:error, [error]} = Decks.parse(deck)
    assert error =~ "duplicate slide ids"
  end

  test "rejects oversized strings, oversized lists, and too many slides" do
    assert {:error, [error]} = Decks.parse(minimal(%{"body" => String.duplicate("x", 5_000)}))
    assert error =~ "at most"

    many_points = for i <- 1..30, do: %{"label" => "P#{i}", "body" => "b"}

    points_deck =
      minimal(%{"layout" => "points", "heading" => "h", "points" => many_points})
      |> update_in(["slides", Access.at(0)], &Map.delete(&1, "body"))

    assert {:error, errors} = Decks.parse(points_deck)
    assert Enum.any?(errors, &(&1 =~ "at most"))

    slides = for i <- 1..41, do: %{"id" => "s#{i}", "layout" => "statement", "body" => "b"}
    assert {:error, [error]} = Decks.parse(%{"title" => "T", "slides" => slides})
    assert error =~ "at most 40 slides"
  end

  test "rejects HTML tags in text fields but not in code" do
    assert {:error, [error]} = Decks.parse(minimal(%{"body" => "hi <b>there</b>"}))
    assert error =~ "HTML tags are not allowed"

    # Plain angle brackets are not tags
    assert {:ok, _} = Decks.parse(minimal(%{"body" => "x < y and y > z"}))

    code_deck =
      minimal(%{"layout" => "big_code", "code" => "<html><body>hi</body></html>"})
      |> update_in(["slides", Access.at(0)], &Map.delete(&1, "body"))

    assert {:ok, _} = Decks.parse(code_deck)
  end

  test "rejects a local media src that escapes priv/static via traversal" do
    deck =
      minimal(%{"layout" => "media", "kind" => "image", "src" => "/../../../../../etc/passwd"})
      |> update_in(["slides", Access.at(0)], &Map.delete(&1, "body"))

    assert {:error, errors} = Decks.parse(deck)
    assert Enum.any?(errors, &(&1 =~ "does not exist"))
  end

  test "block paths support key, key.index, and key.index.field" do
    raw = %{
      "title" => "T",
      "slides" => [
        %{
          "id" => "s0",
          "layout" => "flow",
          "steps" => [
            %{"actor" => "A", "body" => "first"},
            %{"actor" => "B", "body" => "second"}
          ]
        }
      ]
    }

    assert Decks.get_block(raw, 0, "steps.1.body") == "second"

    raw = Decks.put_block(raw, 0, "steps.1.body", "rewritten")
    assert Decks.get_block(raw, 0, "steps.1.body") == "rewritten"

    raw = Decks.delete_block(raw, 0, "steps.1.body")
    assert Decks.get_block(raw, 0, "steps.1.body") == nil
    assert Decks.get_block(raw, 0, "steps.1.actor") == "B"

    # Unparseable / out-of-range paths are safe no-ops
    assert Decks.get_block(raw, 0, "steps.nope") == nil
    assert Decks.put_block(raw, 0, "..bad..", "x") == raw
    assert Decks.delete_block(raw, 0, "steps.99.body") == raw
  end

  test "migrate stamps the version and backfills unique slide ids" do
    raw = %{
      "title" => "T",
      "slides" => [
        %{"layout" => "statement", "body" => "no id"},
        %{"id" => "s1", "layout" => "statement", "body" => "explicit"},
        %{"id" => "s1", "layout" => "statement", "body" => "duplicate"}
      ]
    }

    migrated = Decks.migrate(raw)

    assert migrated["v"] == 1
    ids = Enum.map(migrated["slides"], & &1["id"])
    assert Enum.all?(ids, &(is_binary(&1) and &1 != ""))
    assert ids == Enum.uniq(ids)
    # The explicit id survives on its first holder
    assert Enum.at(migrated["slides"], 1)["id"] == "s1"
    # Idempotent
    assert Decks.migrate(migrated) == migrated
  end

  test "an image part is valid on any layout, with a strict shape" do
    ok = %{"asset_id" => "ast_0123456789abcdef", "alt" => "a photo", "treatment" => "full"}
    assert {:ok, _} = Decks.parse(minimal(%{"image" => ok}))

    bullets =
      %{
        "title" => "T",
        "slides" => [
          %{
            "layout" => "bullets",
            "heading" => "h",
            "columns" => [["one"]],
            "image" => %{"asset_id" => "ast_0123456789abcdef"}
          }
        ]
      }

    assert {:ok, _} = Decks.parse(bullets)

    # A model-inventable id shape is rejected
    assert {:error, [error]} = Decks.parse(minimal(%{"image" => %{"asset_id" => "hax"}}))
    assert error =~ "not a valid asset id"

    assert {:error, [error]} =
             Decks.parse(
               minimal(%{
                 "image" => %{"asset_id" => "ast_0123456789abcdef", "treatment" => "hero"}
               })
             )

    assert error =~ "treatment"

    assert {:error, [error]} =
             Decks.parse(
               minimal(%{
                 "image" => %{"asset_id" => "ast_0123456789abcdef", "onclick" => "x()"}
               })
             )

    assert error =~ "unknown keys"
  end

  test "schema_prompt stays in sync with the design system" do
    prompt = Decks.schema_prompt()

    for layout <- Decks.layouts(), do: assert(prompt =~ ~s("#{layout}"))
    for accent <- Decks.accents(), do: assert(prompt =~ accent)
    for theme <- Decks.themes(), do: assert(prompt =~ theme)
    for tone <- Decks.tones(), do: assert(prompt =~ tone)
    assert prompt =~ "required"
    assert prompt =~ "NON-EMPTY"
  end
end
