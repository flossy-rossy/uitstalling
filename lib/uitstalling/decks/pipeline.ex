defmodule Uitstalling.Decks.Pipeline do
  @moduledoc """
  Drains the edit-request queue: one GenServer that processes pending requests
  serially (a natural rate limit), calls the agent, validates the result with
  the same schema that polices the UI, and broadcasts completion over PubSub
  on the request's deck topic.

  Two request types:
  - "edit" (default): replace one slide of an existing deck
  - "create": generate a whole deck from a topic prompt; theme/voice/accent
    from the form are enforced over whatever the model returns

  Serial worker on purpose — the seam (queue store in, `:deck_updated` /
  `:queue_updated` broadcasts out) is exactly what an Oban worker plugs into
  when this moves to a real DB. On boot it picks up requests left pending by
  a previous run.
  """

  use GenServer

  require Logger

  alias Uitstalling.Decks

  @max_attempts 3

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Nudge the pipeline — call after queueing a request."
  def kick do
    GenServer.cast(__MODULE__, :drain)
  end

  # ----- GenServer ------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :drain}}
  end

  @impl true
  def handle_continue(:drain, state) do
    drain()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:drain, state) do
    drain()
    {:noreply, state}
  end

  # ----- Work loop ------------------------------------------------------------

  defp drain do
    case Decks.pending_requests() do
      [] ->
        :ok

      [request | _rest] ->
        process(request)
        drain()
    end
  end

  defp process(request) do
    result =
      case request["type"] do
        "create" -> attempt_create(request, [], 1)
        _ -> attempt_edit(request, [], 1)
      end

    case result do
      :ok ->
        finish(request, %{"status" => "done"})

      {:error, reason} ->
        Logger.warning("deck request #{request["id"]} failed: #{inspect(reason)}")
        finish(request, %{"status" => "failed", "error" => inspect(reason)})
    end
  end

  # ----- Edit: replace one slide ------------------------------------------------

  defp attempt_edit(_request, errors, attempt) when attempt > @max_attempts do
    {:error, {:validation_failed, errors}}
  end

  defp attempt_edit(request, errors, attempt) do
    raw = Decks.load_raw!(request["deck_id"])

    with {:ok, slide} <- Decks.Agent.impl().generate_slide(raw, request, errors),
         index when not is_nil(index) <- slide_index(raw, request),
         new_raw = put_in(raw, ["slides", Access.at(index)], keep_id(slide, request)),
         {:ok, _deck} <- Decks.parse(new_raw) do
      Decks.save!(request["deck_id"], new_raw)
      :ok
    else
      {:error, new_errors} when is_list(new_errors) ->
        attempt_edit(request, new_errors, attempt + 1)

      nil ->
        {:error, :slide_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ----- Create: generate a whole deck --------------------------------------------

  defp attempt_create(_request, errors, attempt) when attempt > @max_attempts do
    {:error, {:validation_failed, errors}}
  end

  defp attempt_create(request, errors, attempt) do
    with {:ok, generated} <- Decks.Agent.impl().generate_deck(request, errors),
         raw = enforce_choices(generated, request),
         {:ok, _deck} <- Decks.parse(raw) do
      Decks.save!(request["deck_id"], raw)
      :ok
    else
      {:error, new_errors} when is_list(new_errors) ->
        attempt_create(request, new_errors, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The form's choices are authoritative — never trust the model with them.
  # Slides also get ids if the model forgot any.
  defp enforce_choices(generated, request) do
    generated
    |> Map.merge(%{
      "theme" => request["theme"],
      "accent" => request["accent"],
      "voice" => request["voice"]
    })
    |> Map.update("slides", [], fn slides ->
      slides
      |> Enum.with_index()
      |> Enum.map(fn {slide, i} ->
        if is_map(slide), do: Map.put_new(slide, "id", "s#{i}"), else: slide
      end)
    end)
  end

  # ----- Shared -----------------------------------------------------------------

  # Slides can move between queue time and processing — find by stable id,
  # falling back to the queued index.
  defp slide_index(raw, request) do
    slides = raw["slides"]

    case Enum.find_index(slides, &(&1["id"] == request["slide_id"])) do
      nil -> if request["slide_index"] < length(slides), do: request["slide_index"]
      index -> index
    end
  end

  defp keep_id(slide, request) do
    Map.put_new(slide, "id", request["slide_id"])
  end

  defp finish(request, attrs) do
    attrs =
      Map.put(
        attrs,
        "done_at",
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )

    Decks.update_request(request["id"], attrs)

    topic = "deck:#{request["deck_id"]}"
    Phoenix.PubSub.broadcast(Uitstalling.PubSub, topic, :deck_updated)
    Phoenix.PubSub.broadcast(Uitstalling.PubSub, topic, :queue_updated)
  end
end
