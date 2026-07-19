defmodule Uitstalling.Decks.DeckWorkerTest do
  # async: false — mutates the shared demo deck + queue
  use Uitstalling.DataCase, async: false

  alias Uitstalling.Assets
  alias Uitstalling.Decks
  alias Uitstalling.Decks.DeckWorker

  @topic "deck:demo"

  setup do
    %{user: user} = Uitstalling.Fixtures.demo_deck_fixture()
    Phoenix.PubSub.subscribe(Uitstalling.PubSub, @topic)
    on_exit(fn -> File.rm_rf("tmp/test-uploads") end)
    %{user: user}
  end

  defp queue_edit(prompt, overrides \\ %{}) do
    Decks.queue_request(
      Map.merge(
        %{
          "type" => "edit",
          "deck_id" => "demo",
          "slide_id" => "s1",
          "slide_index" => 1,
          "layout" => "statement",
          "block" => nil,
          "prompt" => prompt
        },
        overrides
      )
    )
  end

  defp await_status(request_id, status, tries \\ 100)

  defp await_status(request_id, status, 0) do
    flunk("request #{request_id} never reached #{inspect(status)}")
  end

  defp await_status(request_id, status, tries) do
    current =
      Decks.load_requests()
      |> Enum.find(&(&1["id"] == request_id))
      |> Map.fetch!("status")

    unless current == status do
      Process.sleep(10)
      await_status(request_id, status, tries - 1)
    end
  end

  defp queue_asset(prompt, overrides \\ %{}) do
    Decks.queue_request(
      Map.merge(
        %{
          "type" => "asset",
          "deck_id" => "demo",
          "slide_id" => "s1",
          "block" => "image",
          "prompt" => prompt
        },
        overrides
      )
    )
  end

  # ----- Text edits ---------------------------------------------------------

  test "drains pending requests left over from a previous run on boot" do
    queue_edit("make it pop")

    start_supervised!({DeckWorker, "demo"})

    assert_receive :deck_updated, 2_000
    assert_receive :queue_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "done"

    raw = Decks.load_raw!("demo")
    assert Enum.at(raw["slides"], 1)["heading"] == "AGENT: make it pop"
    assert {:ok, _deck} = Decks.parse(raw)
  end

  test "marks a request failed when the agent can't produce a valid slide" do
    queue_edit("FAIL: return garbage")

    start_supervised!({DeckWorker, "demo"})
    assert_receive :queue_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "failed"
    assert request["error"] =~ "validation_failed"

    assert {:ok, _deck} = Decks.parse(Decks.load_raw!("demo"))

    assert Enum.at(Decks.load_raw!("demo")["slides"], 1)["heading"] ==
             "Ask the ==right question.=="
  end

  test "finds the slide by stable id even when its index moved" do
    raw = Decks.save!("demo", Decks.delete_slide(Decks.load_raw!("demo"), 0))
    assert Enum.at(raw["slides"], 0)["id"] == "s1"

    queue_edit("still finds me")

    start_supervised!({DeckWorker, "demo"})
    assert_receive :deck_updated, 2_000

    assert Enum.at(Decks.load_raw!("demo")["slides"], 0)["heading"] == "AGENT: still finds me"
  end

  test "repairs malformed JSON through the retry loop instead of failing on attempt 1" do
    queue_edit("GARBAGE_THEN_OK: reword this")

    start_supervised!({DeckWorker, "demo"})
    assert_receive :deck_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "done"

    assert Enum.at(Decks.load_raw!("demo")["slides"], 1)["heading"] ==
             "AGENT: GARBAGE_THEN_OK: reword this"
  end

  test "the request's slide id is authoritative over whatever id the model echoes" do
    ids_before = Enum.map(Decks.load_raw!("demo")["slides"], & &1["id"])

    queue_edit("WRONG_ID: touch this")

    start_supervised!({DeckWorker, "demo"})
    assert_receive :deck_updated, 2_000

    raw = Decks.load_raw!("demo")
    assert Enum.map(raw["slides"], & &1["id"]) == ids_before
    assert Enum.at(raw["slides"], 1)["heading"] == "AGENT: WRONG_ID: touch this"
  end

  # ----- Scoped edits (the op path) --------------------------------------------

  test "a field-scoped edit lands as ops, touching nothing else" do
    before = Enum.at(Decks.load_raw!("demo")["slides"], 1)

    queue_edit("tighten this up", %{"block" => "heading"})

    start_supervised!({DeckWorker, "demo"})
    assert_receive :deck_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "done"

    slide = Enum.at(Decks.load_raw!("demo")["slides"], 1)
    assert slide["heading"] == "AGENT: tighten this up"
    assert Map.delete(slide, "heading") == Map.delete(before, "heading")
  end

  test "a part-scoped edit targets the part by its stable id" do
    # Demo slide s3 is the flow slide; migrate backfilled part ids
    steps_before = Enum.at(Decks.load_raw!("demo")["slides"], 3)["steps"]
    assert Enum.all?(steps_before, &is_binary(&1["id"]))

    queue_edit("reword this step", %{
      "slide_id" => "s3",
      "slide_index" => 3,
      "layout" => "flow",
      "block" => "steps.1"
    })

    start_supervised!({DeckWorker, "demo"})
    assert_receive :deck_updated, 2_000

    steps = Enum.at(Decks.load_raw!("demo")["slides"], 3)["steps"]
    assert Enum.at(steps, 1)["body"] == "AGENT: reword this step"
    # Identity and neighbours intact
    assert Enum.map(steps, & &1["id"]) == Enum.map(steps_before, & &1["id"])
    assert Enum.at(steps, 0) == Enum.at(steps_before, 0)
    assert Enum.at(steps, 2) == Enum.at(steps_before, 2)
  end

  test "garbage ops are repaired through the retry loop" do
    queue_edit("OPS_GARBAGE_THEN_OK: fix the heading", %{"block" => "heading"})

    start_supervised!({DeckWorker, "demo"})
    assert_receive :deck_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "done"

    assert Enum.at(Decks.load_raw!("demo")["slides"], 1)["heading"] ==
             "AGENT: OPS_GARBAGE_THEN_OK: fix the heading"
  end

  test "out-of-scope ops are rejected and the model is retried" do
    queue_edit("OPS_OUT_OF_SCOPE_THEN_OK: fix the heading", %{"block" => "heading"})

    start_supervised!({DeckWorker, "demo"})
    assert_receive :deck_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "done"

    slide = Enum.at(Decks.load_raw!("demo")["slides"], 1)
    assert slide["heading"] == "AGENT: OPS_OUT_OF_SCOPE_THEN_OK: fix the heading"
    refute slide["kicker"] == "SNEAKY"
  end

  test "an ops edit that can never parse exhausts its retries and fails" do
    queue_edit("FAIL: forbidden field forever", %{"block" => "heading"})

    start_supervised!({DeckWorker, "demo"})
    assert_receive :queue_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "failed"
    assert request["error"] =~ "validation_failed"

    # Deck untouched
    assert Enum.at(Decks.load_raw!("demo")["slides"], 1)["heading"] ==
             "Ask the ==right question.=="
  end

  test "the slide's image survives an agent edit even when the model vandalizes it" do
    image = %{"asset_id" => "ast_0123456789abcdef", "alt" => "kept"}
    raw = Decks.load_raw!("demo")

    raw =
      put_in(raw, ["slides", Access.at(1)], Map.put(Enum.at(raw["slides"], 1), "image", image))

    Decks.save!("demo", raw)

    queue_edit("IMAGE_VANDAL: try to replace the image")

    start_supervised!({DeckWorker, "demo"})
    assert_receive :deck_updated, 2_000

    slide = Enum.at(Decks.load_raw!("demo")["slides"], 1)
    assert slide["image"] == image
    assert slide["heading"] == "AGENT: IMAGE_VANDAL: try to replace the image"
  end

  test "an edit for a deleted slide fails instead of retargeting by stale index" do
    queue_edit("too late", %{"slide_id" => "s0", "slide_index" => 0, "layout" => "title"})

    # The slide vanishes while the request is still queued
    Decks.save!("demo", Decks.delete_slide(Decks.load_raw!("demo"), 0))

    start_supervised!({DeckWorker, "demo"})
    assert_receive :queue_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "failed"
    assert request["error"] =~ "slide_not_found"

    refute Enum.any?(Decks.load_raw!("demo")["slides"], &(&1["heading"] == "AGENT: too late"))
  end

  test "requests stuck in processing from a crashed run are failed on boot" do
    request = queue_edit("was in flight")
    Decks.mark_processing(request["id"])

    pid = start_supervised!({DeckWorker, "demo"})
    # Synchronize: get_state only returns once init's handle_continue drain
    # (which includes the stale-processing sweep) has run.
    _ = :sys.get_state(pid)

    [stored] = Decks.load_requests()
    assert stored["status"] == "failed"
    assert stored["error"] == "interrupted by restart"
  end

  # ----- Creates --------------------------------------------------------------

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

    start_supervised!({DeckWorker, deck_id})
    assert_receive :deck_updated, 2_000

    raw = Decks.load_raw!(deck_id)
    assert raw["title"] == "FAKE DECK: why passkeys beat passwords"
    assert raw["theme"] == "midnight"
    assert raw["accent"] == "cyan"
    assert raw["voice"] == "friendly, non-technical"
    assert Enum.all?(raw["slides"], &is_binary(&1["id"]))

    # The model's title-slide image_request never reaches the stored deck —
    # it becomes a queued asset request the same worker drains next.
    refute Map.has_key?(hd(raw["slides"]), "image_request")
    assert_receive :deck_updated, 2_000

    raw = Decks.load_raw!(deck_id)
    assert %{"asset_id" => "ast_" <> _} = hd(raw["slides"])["image"]

    requests = Decks.load_requests()
    assert Enum.map(requests, & &1["type"]) == ["create", "asset"]
    assert Enum.all?(requests, &(&1["status"] == "done"))
    assert Enum.find(requests, &(&1["type"] == "asset"))["slide_id"] == "s0"
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

    start_supervised!({DeckWorker, deck_id})
    assert_receive :queue_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "failed"
    assert Decks.load_raw!(deck_id)["title"] == "New presentation"
  end

  # ----- Image generation ------------------------------------------------------

  test "generates an image from a queued asset request and attaches it to the slide" do
    queue_asset("an isometric phishing proxy")

    start_supervised!({DeckWorker, "demo"})
    assert_receive :deck_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "done"

    slide = Enum.at(Decks.load_raw!("demo")["slides"], 1)
    assert %{"asset_id" => "ast_" <> _} = slide["image"]
    # No visible caption by default — the subject lives on the asset only,
    # where the editor's regenerate flow offers it back.
    refute Map.has_key?(slide["image"], "alt")

    asset = Assets.get(slide["image"]["asset_id"])
    assert asset.origin == "gen"
    assert asset.prompt == "an isometric phishing proxy"
    assert Assets.ready?(asset.id)

    # The GENERATOR got the composed prompt (subject + deck/slide art
    # direction) — the fake echoes its prompt into the stored bytes.
    assert {:file, path, "image/png"} = Assets.serve(asset)
    generated_from = File.read!(path)
    assert generated_from =~ "an isometric phishing proxy"
    assert generated_from =~ "amber"
    assert generated_from =~ "Passwordless / WebAuthn"
    assert generated_from =~ "§ 0 · FRAMING"
  end

  test "a failed generation marks the request failed and leaves the slide untouched" do
    slide_before = Enum.at(Decks.load_raw!("demo")["slides"], 1)

    queue_asset("FAIL: broken provider")

    start_supervised!({DeckWorker, "demo"})
    assert_receive :queue_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "failed"
    assert request["error"] =~ "fake_generation_failed"
    assert Enum.at(Decks.load_raw!("demo")["slides"], 1) == slide_before
  end

  test "an asset request for a slide deleted mid-flight fails cleanly" do
    queue_asset("too late", %{"slide_id" => "s0"})

    Decks.save!("demo", Decks.delete_slide(Decks.load_raw!("demo"), 0))

    start_supervised!({DeckWorker, "demo"})
    assert_receive :queue_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "failed"
    assert request["error"] =~ "slide_not_found"
  end

  test "a stalling provider is bounded by the generation timeout, not spun on forever" do
    # test config sets :image_gen_timeout to 500ms; the SLOW fake stalls for
    # exactly that (as the real HTTP client would) then errors
    queue_asset("SLOW: never answers")

    start_supervised!({DeckWorker, "demo"})
    assert_receive :queue_updated, 2_000

    [request] = Decks.load_requests()
    assert request["status"] == "failed"
    assert request["error"] =~ "timeout"
  end

  test "canceling mid-generation discards the result, and the worker moves on" do
    slow = queue_asset("SLOW: user will give up")
    next = queue_asset("a follow-up image", %{"slide_id" => "s2"})

    start_supervised!({DeckWorker, "demo"})

    # The worker blocks inside the generation call (that's the design), so we
    # can't sync via :sys.get_state — poll until it has picked the request
    # up, well inside the fake provider's 500ms stall.
    await_status(slow["id"], "processing")

    # What the cancel button does, while the worker is blocked generating:
    Decks.cancel_request(slow["id"])

    # First finish is the discarded slow request, second is the follow-up
    assert_receive :deck_updated, 2_000
    assert_receive :deck_updated, 2_000

    statuses = Map.new(Decks.load_requests(), &{&1["id"], &1["status"]})
    assert statuses[slow["id"]] == "canceled"
    assert statuses[next["id"]] == "done"

    # Only the follow-up's slide gained an image
    refute Enum.find(Decks.load_raw!("demo")["slides"], &(&1["id"] == "s1"))["image"]
    assert Enum.find(Decks.load_raw!("demo")["slides"], &(&1["id"] == "s2"))["image"]
  end

  test "canceling a pending (not yet started) request just skips it" do
    request = queue_asset("never wanted")
    Decks.cancel_request(request["id"])

    pid = start_supervised!({DeckWorker, "demo"})
    _ = :sys.get_state(pid)

    [stored] = Decks.load_requests()
    assert stored["status"] == "canceled"
    refute Enum.at(Decks.load_raw!("demo")["slides"], 1)["image"]
  end

  test "the text agent's image_request flows through to a generated, attached image" do
    queue_edit("WANTS_IMAGE: add a diagram")

    # One worker, one drain: the edit lands, queues the asset request onto
    # this same deck's queue, and the drain loop picks it up immediately.
    start_supervised!({DeckWorker, "demo"})

    assert_receive :deck_updated, 2_000
    assert_receive :deck_updated, 2_000

    slide = Enum.at(Decks.load_raw!("demo")["slides"], 1)
    assert slide["heading"] == "AGENT: WANTS_IMAGE: add a diagram"
    assert %{"asset_id" => "ast_" <> _} = slide["image"]
    assert Assets.get(slide["image"]["asset_id"]).prompt =~ "a diagram of the login flow"
  end
end
