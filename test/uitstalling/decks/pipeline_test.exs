defmodule Uitstalling.Decks.PipelineTest do
  # async: false — mutates the shared deck + queue files
  use Uitstalling.DataCase, async: false

  alias Uitstalling.Decks
  alias Uitstalling.Decks.Pipeline

  @topic "deck:demo"

  setup do
    %{user: user} = Uitstalling.Fixtures.demo_deck_fixture()
    Phoenix.PubSub.subscribe(Uitstalling.PubSub, @topic)
    %{user: user}
  end

  test "drains pending requests left over from a previous run on boot" do
    Decks.queue_request(%{
      "type" => "edit",
      "deck_id" => "demo",
      "slide_id" => "s1",
      "slide_index" => 1,
      "layout" => "statement",
      "block" => nil,
      "prompt" => "make it pop"
    })

    start_supervised!(Pipeline)

    assert_receive :deck_updated, 2_000
    assert_receive :queue_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "done"

    raw = Decks.load_raw!("demo")
    assert Enum.at(raw["slides"], 1)["heading"] == "AGENT: make it pop"

    # The result went through the validator before being persisted
    assert {:ok, _deck} = Decks.parse(raw)
  end

  test "marks a request failed when the agent can't produce a valid slide" do
    Decks.queue_request(%{
      "type" => "edit",
      "deck_id" => "demo",
      "slide_id" => "s1",
      "slide_index" => 1,
      "layout" => "statement",
      "block" => nil,
      "prompt" => "FAIL: return garbage"
    })

    start_supervised!(Pipeline)

    assert_receive :queue_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "failed"
    assert request["error"] =~ "validation_failed"

    # The deck was never corrupted
    assert {:ok, _deck} = Decks.parse(Decks.load_raw!("demo"))

    assert Enum.at(Decks.load_raw!("demo")["slides"], 1)["heading"] ==
             "Ask the ==right question.=="
  end

  test "finds the slide by stable id even when its index moved" do
    # Delete slide 0 so the statement slide shifts from index 1 to 0
    raw = Decks.save!("demo", Decks.delete_slide(Decks.load_raw!("demo"), 0))
    assert Enum.at(raw["slides"], 0)["id"] == "s1"

    Decks.queue_request(%{
      "type" => "edit",
      "deck_id" => "demo",
      "slide_id" => "s1",
      "slide_index" => 1,
      "layout" => "statement",
      "block" => nil,
      "prompt" => "still finds me"
    })

    start_supervised!(Pipeline)
    assert_receive :deck_updated, 2_000

    assert Enum.at(Decks.load_raw!("demo")["slides"], 0)["heading"] == "AGENT: still finds me"
  end

  test "creates a whole deck from a create request, enforcing form choices", %{user: user} do
    deck_id = Decks.generate_id()
    Phoenix.PubSub.subscribe(Uitstalling.PubSub, "deck:#{deck_id}")

    Decks.create_deck!(user.id, deck_id, %{
      "title" => "New presentation",
      "theme" => "midnight",
      "accent" => "cyan",
      "slides" => [%{"id" => "s0", "layout" => "statement", "body" => "Generating…"}]
    })

    Decks.queue_request(%{
      "type" => "create",
      "deck_id" => deck_id,
      "theme" => "midnight",
      "accent" => "cyan",
      "voice" => "friendly, non-technical",
      "minutes" => 10,
      "target_slides" => 8,
      "prompt" => "why passkeys beat passwords"
    })

    start_supervised!(Pipeline)
    assert_receive :deck_updated, 2_000

    raw = Decks.load_raw!(deck_id)
    assert raw["title"] == "FAKE DECK: why passkeys beat passwords"
    # Form choices win over whatever the model returned
    assert raw["theme"] == "midnight"
    assert raw["accent"] == "cyan"
    assert raw["voice"] == "friendly, non-technical"
    assert Enum.all?(raw["slides"], &is_binary(&1["id"]))

    [request] = Decks.load_requests()
    assert request["status"] == "done"
  end

  test "a failed create leaves the stub deck intact", %{user: user} do
    deck_id = Decks.generate_id()
    Phoenix.PubSub.subscribe(Uitstalling.PubSub, "deck:#{deck_id}")

    stub = %{
      "title" => "New presentation",
      "slides" => [%{"id" => "s0", "layout" => "statement", "body" => "Generating…"}]
    }

    Decks.create_deck!(user.id, deck_id, stub)

    Decks.queue_request(%{
      "type" => "create",
      "deck_id" => deck_id,
      "theme" => "noir",
      "accent" => "amber",
      "voice" => "any",
      "minutes" => 10,
      "target_slides" => 8,
      "prompt" => "FAIL: garbage deck"
    })

    start_supervised!(Pipeline)
    assert_receive :queue_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "failed"
    assert Decks.load_raw!(deck_id)["title"] == "New presentation"
  end
end
