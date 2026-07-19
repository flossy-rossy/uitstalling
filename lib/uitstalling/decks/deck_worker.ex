defmodule Uitstalling.Decks.DeckWorker do
  @moduledoc """
  One worker per deck, started on demand: drains THIS deck's request queue —
  text edits, whole-deck creates, and image generation — strictly in order.

  Per-deck serialization is the point: every request is a load-whole-document
  → mutate → save-whole-document cycle, so two workers touching the same deck
  could clobber each other's writes (an image attaching mid-edit would eat
  the edit). One worker per deck makes that impossible, while decks never
  block each other — deck A's minute-long create doesn't delay deck B's
  one-line edit.

  Image generation deliberately BLOCKS this worker (no async task): it only
  holds up this deck's own queue, is bounded by the generator's HTTP timeout
  (`:image_gen_timeout`), and a cancel flips the request row — the worker
  checks it before persisting, so a canceled generation is discarded the
  moment the provider answers (or times out).

  Every failure the model can plausibly repair — validator rejections,
  malformed/truncated JSON, block-scope violations — is fed back as an error
  list (with the rejected attempt) for up to 3 tries. A request is marked
  "processing" while in flight; the worker sweeps its own deck's stale
  "processing" rows on boot (a crashed run's leftovers) rather than
  replaying them forever.

  Workers are resident once started (a deck is a handful of KB of state) —
  idle shutdown is a later optimization, not correctness.
  """

  use GenServer, restart: :transient

  require Logger

  alias Uitstalling.Assets
  alias Uitstalling.Decks
  alias Uitstalling.Decks.Agent.Context
  alias Uitstalling.Decks.BlockPath
  alias Uitstalling.Decks.Op
  alias Uitstalling.Decks.Op.{DeleteField, ReplacePart, SetField}

  @max_attempts 3

  @doc """
  Ensure this deck's worker is running and nudge it — call after queueing a
  request. With `:start_pipeline` off (tests), workers are never started
  implicitly — eager draining would race pending-state assertions — but a
  worker a test started explicitly still gets the nudge.
  """
  def kick(deck_id) do
    if Application.get_env(:uitstalling, :start_pipeline, true) do
      case DynamicSupervisor.start_child(
             Uitstalling.Decks.WorkerSupervisor,
             {__MODULE__, deck_id}
           ) do
        {:ok, pid} -> GenServer.cast(pid, :drain)
        {:error, {:already_started, pid}} -> GenServer.cast(pid, :drain)
        {:error, _reason} -> :ok
      end
    else
      case Registry.lookup(Uitstalling.Decks.Registry, deck_id) do
        [{pid, _value}] -> GenServer.cast(pid, :drain)
        [] -> :ok
      end
    end

    :ok
  end

  @doc "Kick a worker for every deck with unfinished requests (app boot)."
  def kick_unfinished do
    Enum.each(Decks.unfinished_deck_ids(), &kick/1)
  end

  def start_link(deck_id) do
    GenServer.start_link(__MODULE__, deck_id, name: via(deck_id))
  end

  defp via(deck_id), do: {:via, Registry, {Uitstalling.Decks.Registry, deck_id}}

  # ----- GenServer ------------------------------------------------------------

  @impl true
  def init(deck_id) do
    {:ok, %{deck_id: deck_id}, {:continue, :drain}}
  end

  @impl true
  def handle_continue(:drain, state) do
    Decks.fail_stale_processing(state.deck_id)
    drain(state.deck_id)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:drain, state) do
    drain(state.deck_id)
    {:noreply, state}
  end

  # ----- Work loop ------------------------------------------------------------

  defp drain(deck_id) do
    case Decks.pending_deck_requests(deck_id) do
      [] ->
        :ok

      [request | _rest] ->
        process(request)
        drain(deck_id)
    end
  end

  defp process(request) do
    Decks.mark_processing(request["id"])

    result =
      try do
        case request["type"] do
          "create" ->
            attempt_create(request, nil, 1)

          "asset" ->
            generate_and_attach(request)

          _ ->
            # Scoped edits go through the op vocabulary (docs/edit-ops.md);
            # whole-slide rework keeps the replacement path.
            if request["block"],
              do: attempt_ops(request, nil, 1),
              else: attempt_edit(request, nil, 1)
        end
      rescue
        exception ->
          Logger.error(
            "deck request #{request["id"]} crashed: " <>
              Exception.format(:error, exception, __STACKTRACE__)
          )

          {:error, {:crashed, Exception.message(exception)}}
      end

    case result do
      :ok ->
        finish(request, %{"status" => "done"})

      {:error, :canceled} ->
        # Cancel already flipped the row; the guarded update no-ops and the
        # broadcasts clear the UI.
        finish(request, %{"status" => "canceled"})

      {:error, reason} ->
        Logger.warning("deck request #{request["id"]} failed: #{inspect(reason)}")
        finish(request, %{"status" => "failed", "error" => inspect(reason)})
    end
  end

  # ----- Edit: replace one slide ------------------------------------------------

  defp attempt_edit(request, retry, attempt) do
    raw = Decks.load_raw!(request["deck_id"])

    case Decks.Agent.impl().generate_slide(raw, request, retry) do
      {:ok, slide} ->
        apply_slide(raw, slide, request, attempt)

      {:error, reason} ->
        case repair_errors(reason) do
          nil -> {:error, reason}
          errors -> retry_edit(request, errors, nil, attempt)
        end
    end
  end

  defp apply_slide(raw, slide, request, attempt) do
    case slide_index(raw, request) do
      nil ->
        {:error, :slide_not_found}

      index ->
        original = Enum.at(raw["slides"], index)

        # The model can't attach images itself — it REQUESTS one via an
        # "image_request" key, popped here so it never reaches the validator.
        {image_request, slide} =
          if is_map(slide), do: Map.pop(slide, "image_request"), else: {nil, slide}

        # The request's slide_id is authoritative — a model that echoes a
        # different (or duplicate) id must not be able to break addressing.
        # App-managed keys (e.g. "image") survive every edit the same way:
        # whatever the model emitted is stripped and the original restored.
        slide =
          if is_map(slide),
            do: slide |> Map.put("id", request["slide_id"]) |> restore_app_keys(original),
            else: slide

        new_raw = put_in(raw, ["slides", Access.at(index)], slide)

        with :ok <- edit_validation(new_raw, index),
             :ok <- not_canceled(request) do
          Decks.save!(request["deck_id"], new_raw)
          queue_image_request(request, image_request)
          :ok
        else
          {:retry, errors} -> retry_edit(request, errors, slide, attempt)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The model asked for an image ("add a diagram of X" style edits): queue it
  # as this deck's next request — the drain loop picks it up right after this
  # edit finishes, in order, on this same worker.
  defp queue_image_request(request, %{"subject" => subject}) when is_binary(subject) do
    if String.trim(subject) != "" do
      Decks.queue_request(%{
        "type" => "asset",
        "deck_id" => request["deck_id"],
        "slide_id" => request["slide_id"],
        "block" => "image",
        "prompt" => subject
      })
    end

    :ok
  end

  defp queue_image_request(_request, _other), do: :ok

  defp retry_edit(_request, errors, _previous, attempt) when attempt >= @max_attempts do
    {:error, {:validation_failed, errors}}
  end

  defp retry_edit(request, errors, previous, attempt) do
    attempt_edit(request, %{errors: errors, previous: previous}, attempt + 1)
  end

  # Validate the whole deck, but hand the model errors scoped to the slide it
  # actually returned: its own "slides[N]." prefixes read as "slide.", and an
  # error pointing at any OTHER slide means the deck is broken for reasons the
  # model cannot fix by returning this slide — fail fast instead of burning
  # retries.
  defp edit_validation(new_raw, index) do
    case Decks.parse(new_raw) do
      {:ok, _deck} ->
        :ok

      {:error, errors} ->
        if Enum.any?(errors, &other_slide_error?(&1, index)) do
          {:error, {:unrelated_validation_errors, errors}}
        else
          {:retry, Enum.map(errors, &rescope(&1, index))}
        end
    end
  end

  defp other_slide_error?(error, index) do
    String.starts_with?(error, "slides[") and not own_slide_error?(error, index)
  end

  defp own_slide_error?(error, index) do
    String.starts_with?(error, "slides[#{index}].") or
      String.starts_with?(error, "slides[#{index}]:")
  end

  defp rescope(error, index) do
    error
    |> String.replace_prefix("slides[#{index}].", "slide.")
    |> String.replace_prefix("slides[#{index}]:", "slide:")
  end

  # ----- Scoped edits: the op path (docs/edit-ops.md) ----------------------------

  defp attempt_ops(request, retry, attempt) do
    raw = Decks.load_raw!(request["deck_id"])

    case slide_index(raw, request) do
      nil ->
        {:error, :slide_not_found}

      index ->
        slide = Enum.at(raw["slides"], index)

        case resolve_scope(slide, request["block"]) do
          nil ->
            {:error, :block_not_found}

          target ->
            request = Map.put(request, "target", target)

            case Decks.Agent.impl().generate_ops(raw, request, retry) do
              {:ok, reply} ->
                apply_ops(raw, reply, request, index, target, attempt)

              {:error, reason} ->
                case repair_errors(reason) do
                  nil -> {:error, reason}
                  errors -> retry_ops(request, errors, nil, attempt)
                end
            end
        end
    end
  end

  defp apply_ops(raw, reply, request, index, target, attempt) do
    with {:ok, ops} <- Op.parse_batch(reply["ops"], request["slide_id"]),
         :ok <- check_ops_scope(ops, target),
         {:ok, new_raw, _applied} <- Op.apply_batch(raw, ops),
         :ok <- edit_validation(new_raw, index),
         :ok <- not_canceled(request) do
      Decks.save!(request["deck_id"], new_raw)
      :ok
    else
      {:retry, errors} -> retry_ops(request, errors, reply, attempt)
      {:error, errors} when is_list(errors) -> retry_ops(request, errors, reply, attempt)
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_ops(_request, errors, _previous, attempt) when attempt >= @max_attempts do
    {:error, {:validation_failed, errors}}
  end

  defp retry_ops(request, errors, previous, attempt) do
    attempt_ops(request, %{errors: errors, previous: previous}, attempt + 1)
  end

  # What the UI's block path means in op terms, resolved against the current
  # slide: a slide-level field, an id-addressed part, or one field of a part.
  # Index paths into non-part lists (bullets columns, table rows) scope to
  # the whole field — those lists have no part ids (yet).
  defp resolve_scope(slide, block) do
    case BlockPath.parse(block) do
      {:ok, {:key, key}} ->
        %{"kind" => "field", "field" => key}

      {:ok, {:item, key, index}} ->
        case part_id_at(slide, key, index) do
          nil -> %{"kind" => "field", "field" => key}
          id -> %{"kind" => "part", "part" => id}
        end

      {:ok, {:field, key, index, sub}} ->
        case part_id_at(slide, key, index) do
          nil -> %{"kind" => "field", "field" => key}
          id -> %{"kind" => "part_field", "part" => id, "field" => sub}
        end

      :error ->
        nil
    end
  end

  defp part_id_at(slide, key, index) do
    case Enum.at(List.wrap(slide[key]), index) do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  # Scope enforcement by construction: every op in the batch must target the
  # requested field/part — anything else is a repairable violation.
  defp check_ops_scope(ops, target) do
    if Enum.all?(ops, &in_scope?(&1, target)) do
      :ok
    else
      {:retry,
       [
         "ops: out of scope — every op must change only the requested target " <>
           "(#{inspect(target)})"
       ]}
    end
  end

  defp in_scope?(%SetField{part: nil, field: field}, %{"kind" => "field", "field" => field}),
    do: true

  defp in_scope?(%DeleteField{part: nil, field: field}, %{"kind" => "field", "field" => field}),
    do: true

  defp in_scope?(%SetField{part: part}, %{"kind" => "part", "part" => part})
       when is_binary(part),
       do: true

  defp in_scope?(%DeleteField{part: part}, %{"kind" => "part", "part" => part})
       when is_binary(part),
       do: true

  defp in_scope?(%ReplacePart{part: part}, %{"kind" => "part", "part" => part}), do: true

  defp in_scope?(%SetField{part: part, field: field}, %{
         "kind" => "part_field",
         "part" => part,
         "field" => field
       }),
       do: true

  defp in_scope?(%DeleteField{part: part, field: field}, %{
         "kind" => "part_field",
         "part" => part,
         "field" => field
       }),
       do: true

  defp in_scope?(_op, _target), do: false

  @app_keys ~w(image)

  defp restore_app_keys(slide, original) do
    Enum.reduce(@app_keys, Map.drop(slide, @app_keys), fn key, acc ->
      case original[key] do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # ----- Create: generate a whole deck --------------------------------------------

  defp attempt_create(request, retry, attempt) do
    case Decks.Agent.impl().generate_deck(request, retry) do
      {:ok, generated} ->
        # migrate/1 backfills any ids the model forgot (and de-dupes) before
        # validation, so a fresh deck never fails on id bookkeeping. App keys
        # a model hallucinated (an "image" with an invented asset id) are
        # dropped rather than burning a retry. image_request keys are popped
        # AFTER migrate so every slide id they hang off is real.
        raw = generated |> enforce_choices(request) |> strip_app_keys() |> Decks.migrate()
        {raw, image_subjects} = pop_image_requests(raw)

        case {Decks.parse(raw), not_canceled(request)} do
          {{:ok, _deck}, :ok} ->
            Decks.save!(request["deck_id"], raw)
            # The REAL title exists now — mint the public slug from it
            # (never from the "New presentation" stub).
            Decks.ensure_deck_slug(request["deck_id"])
            # The title-slide visual (and any other requested images) queue
            # behind this create — the drain loop picks them up next, so the
            # deck's text is on screen while its images generate.
            queue_created_images(request, image_subjects)
            :ok

          {_, {:error, :canceled}} ->
            {:error, :canceled}

          {{:error, errors}, :ok} ->
            retry_create(request, errors, generated, attempt)
        end

      {:error, reason} ->
        case repair_errors(reason) do
          nil -> {:error, reason}
          errors -> retry_create(request, errors, nil, attempt)
        end
    end
  end

  defp retry_create(_request, errors, _previous, attempt) when attempt >= @max_attempts do
    {:error, {:validation_failed, errors}}
  end

  defp retry_create(request, errors, previous, attempt) do
    attempt_create(request, %{errors: errors, previous: previous}, attempt + 1)
  end

  # The form's choices are authoritative — never trust the model with them.
  # extract_json/1 guarantees the agent's {:ok, _} carries a map.
  defp enforce_choices(generated, request) do
    Map.merge(generated, %{
      "theme" => request["theme"],
      "accent" => request["accent"],
      "voice" => request["voice"]
    })
  end

  defp strip_app_keys(%{"slides" => slides} = raw) when is_list(slides) do
    Map.put(
      raw,
      "slides",
      Enum.map(slides, fn
        %{} = slide -> Map.drop(slide, @app_keys)
        other -> other
      end)
    )
  end

  defp strip_app_keys(raw), do: raw

  # Collect the model's image requests off a freshly-created deck (popped so
  # they never reach the validator), keyed by the migrated slide ids.
  defp pop_image_requests(%{"slides" => slides} = raw) when is_list(slides) do
    {slides, subjects} =
      Enum.map_reduce(slides, [], fn
        %{} = slide, acc ->
          {image_request, slide} = Map.pop(slide, "image_request")

          case image_request do
            %{"subject" => subject} when is_binary(subject) ->
              if String.trim(subject) == "",
                do: {slide, acc},
                else: {slide, [{slide["id"], subject} | acc]}

            _ ->
              {slide, acc}
          end

        other, acc ->
          {other, acc}
      end)

    {Map.put(raw, "slides", slides), Enum.reverse(subjects)}
  end

  defp pop_image_requests(raw), do: {raw, []}

  # Cap what one create can spend on images — the contract asks for the title
  # slide only, but a model that requests more mustn't fan out unbounded.
  defp queue_created_images(request, subjects) do
    subjects
    |> Enum.take(3)
    |> Enum.each(fn {slide_id, subject} ->
      Decks.queue_request(%{
        "type" => "asset",
        "deck_id" => request["deck_id"],
        "slide_id" => slide_id,
        "block" => "image",
        "prompt" => subject
      })
    end)
  end

  # ----- Asset: generate an image and attach it to its slide ----------------------

  defp generate_and_attach(request) do
    raw = Decks.load_raw!(request["deck_id"])

    # Compose the prompt from the deck's theme/title/voice and the slide's
    # own context — and fail BEFORE paying for a generation if the slide is
    # already gone.
    case Enum.find(raw["slides"], &(is_map(&1) and &1["id"] == request["slide_id"])) do
      nil ->
        {:error, :slide_not_found}

      slide ->
        owner_id = Decks.owner_id(request["deck_id"])
        prompt = Context.image_prompt(raw, slide, request["prompt"])

        with {:ok, asset} <-
               Assets.create_generated(owner_id, prompt, subject: request["prompt"]) do
          attach(request, asset)
        end
    end
  end

  # Attach AFTER generation: the deck may have changed during the slow part,
  # so the slide is re-located by id at the last moment, and a cancel that
  # landed mid-generation is honored. A vanished slide fails the request;
  # the stored asset stays (harmless, reusable later).
  defp attach(request, asset) do
    with :ok <- not_canceled(request) do
      raw = Decks.load_raw!(request["deck_id"])

      case Enum.find_index(raw["slides"], &(is_map(&1) and &1["id"] == request["slide_id"])) do
        nil ->
          {:error, :slide_not_found}

        index ->
          existing = Decks.get_block(raw, index, "image") || %{}

          # No visible caption by default — the generation subject lives on
          # the asset for the editor's regenerate flow, not as a footer. A
          # caption/treatment the author set on a previous image survives.
          image =
            %{"asset_id" => asset.id}
            |> maybe_keep(existing, "alt")
            |> maybe_keep(existing, "treatment")

          new_raw = Decks.put_block(raw, index, "image", image)

          case Decks.parse(new_raw) do
            {:ok, _deck} ->
              Decks.save!(request["deck_id"], new_raw)
              :ok

            {:error, errors} ->
              {:error, {:validation_failed, errors}}
          end
      end
    end
  end

  defp maybe_keep(image, existing, key) do
    case existing[key] do
      value when is_binary(value) and value != "" -> Map.put(image, key, value)
      _ -> image
    end
  end

  # ----- Shared -----------------------------------------------------------------

  # Transport-level failures the model can plausibly repair become validator-
  # style error lists so the normal retry loop fires. Anything else (auth,
  # HTTP, refusal) is terminal.
  defp repair_errors(:not_an_object) do
    [
      "response: must be exactly ONE JSON object — respond with only the JSON object, " <>
        "no prose, no markdown fences, no arrays"
    ]
  end

  defp repair_errors({:invalid_json, message}) do
    [
      "response: invalid JSON (#{message}) — respond with only one complete JSON object, " <>
        "no prose or fences"
    ]
  end

  defp repair_errors(:truncated) do
    [
      "response: the reply was cut off before it completed — keep the same scope and " <>
        "quality but trim your LONGEST bodies/notes so the complete JSON object fits; " <>
        "do not drop slides or hollow out the content"
    ]
  end

  defp repair_errors(_reason), do: nil

  # A user hit cancel while the model was thinking — don't persist the result.
  defp not_canceled(request) do
    if Decks.canceled?(request["id"]), do: {:error, :canceled}, else: :ok
  end

  # Slides are addressed by stable id only. load_raw!/1 backfills ids on
  # legacy decks, so a missing id means the slide is gone (e.g. deleted while
  # this request was queued) — never fall back to a positional index that may
  # now point at a different slide.
  defp slide_index(raw, request) do
    Enum.find_index(raw["slides"], &(is_map(&1) and &1["id"] == request["slide_id"]))
  end

  defp finish(request, attrs) do
    attrs =
      Map.put(
        attrs,
        "done_at",
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )

    # No-op if the request was canceled meanwhile — cancel is final.
    Decks.update_request(request["id"], attrs)

    topic = "deck:#{request["deck_id"]}"
    Phoenix.PubSub.broadcast(Uitstalling.PubSub, topic, :deck_updated)
    Phoenix.PubSub.broadcast(Uitstalling.PubSub, topic, :queue_updated)
  end
end
