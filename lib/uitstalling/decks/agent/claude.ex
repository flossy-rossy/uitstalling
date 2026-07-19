defmodule Uitstalling.Decks.Agent.Claude do
  @moduledoc """
  Real agent: one Messages API call per request (Anthropic wire format).

  Prompt layout follows the caching rules: the stable design-system block goes
  first in `system` with a cache breakpoint; the deck JSON — identical across
  retries and consecutive edits of the same deck — goes in a second cached
  system block; only the volatile request/retry text rides in the user turn.
  Configured entirely via env:

    AGENT_API_KEY  — provider API key (required)
    AGENT_MODEL    — model id, per-request parameter (default claude-haiku-4-5)
    AGENT_BASE_URL — Anthropic-compatible endpoint (default https://api.anthropic.com;
                     Z.ai GLM works via https://api.z.ai/api/anthropic)
  """

  @behaviour Uitstalling.Decks.Agent

  require Logger

  alias Uitstalling.Decks

  @impl true
  def generate_slide(deck, request, retry) do
    system = [edit_system_prompt(), edit_context_prompt(deck)]

    with {:ok, api_key} <- fetch_api_key(),
         {:ok, text} <- call_api(api_key, system, edit_user_prompt(deck, request, retry), 4096) do
      extract_json(text)
    end
  end

  @impl true
  def generate_ops(deck, request, retry) do
    system = [ops_system_prompt(), edit_context_prompt(deck)]

    with {:ok, api_key} <- fetch_api_key(),
         {:ok, text} <- call_api(api_key, system, ops_user_prompt(deck, request, retry), 2048) do
      extract_json(text)
    end
  end

  @impl true
  def generate_deck(request, retry) do
    with {:ok, api_key} <- fetch_api_key(),
         {:ok, text} <-
           call_api(api_key, [create_system_prompt()], create_user_prompt(request, retry), 24_000) do
      extract_json(text)
    end
  end

  defp call_api(api_key, system_blocks, user, max_tokens) do
    body = %{
      model: config(:agent_model, "claude-haiku-4-5"),
      max_tokens: max_tokens,
      system:
        Enum.map(system_blocks, fn text ->
          %{type: "text", text: text, cache_control: %{type: "ephemeral"}}
        end),
      messages: [%{role: "user", content: user}]
    }

    url =
      config(:agent_base_url, "https://api.anthropic.com")
      |> String.trim_trailing("/")
      |> Kernel.<>("/v1/messages")

    case Req.post(
           url,
           Uitstalling.HTTP.options(
             json: body,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", "2023-06-01"}
             ],
             receive_timeout: 300_000
           )
         ) do
      {:ok, %Req.Response{status: 200, body: %{"content" => content} = resp}} ->
        case resp["stop_reason"] do
          "refusal" ->
            {:error, :refused}

          "max_tokens" ->
            # The reply was cut off — parsing the fragment would only produce
            # a misleading invalid-JSON error.
            {:error, :truncated}

          _ ->
            text =
              content
              |> Enum.filter(&(&1["type"] == "text"))
              |> Enum.map_join("", & &1["text"])

            {:ok, text}
        end

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.warning(
          "agent API error #{status} — POST #{url} model=#{body.model}: #{inspect(resp_body)}"
        )

        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # ----- Prompts (shared with the OpenAI-shaped client) -------------------------

  @doc false
  def edit_system_prompt do
    """
    You are a slide-deck edit agent for a presentation builder. You receive a
    deck (JSON), one edit request targeting a single slide, and you return the
    COMPLETE replacement JSON object for that one slide.

    Rules:
    - Respond with ONLY the slide JSON object. No prose, no markdown fences.
    - Stay strictly within the design system described below. Unknown keys,
      unknown layouts, and off-palette values are rejected by a validator.
    - Preserve the slide's "id" and any fields the request doesn't ask you to
      change. When the request scopes the edit to one named part ("block"),
      every other field must be returned byte-for-byte unchanged.
    - Match the deck's writing voice.

    #{Decks.schema_prompt()}
    """
  end

  # The deck is stable across retries and consecutive edits — it lives in its
  # own system block so the API can cache it separately from the request.
  @doc false
  def edit_context_prompt(deck) do
    voice =
      case deck["voice"] do
        v when is_binary(v) and v != "" ->
          v

        _ ->
          "not set — infer the voice from the existing slides' text and match it exactly"
      end

    """
    Deck voice: #{voice}

    Full deck for context:
    #{Jason.encode!(deck)}
    """
  end

  @doc false
  def edit_user_prompt(deck, request, retry) do
    """
    Edit request for the slide with id=#{request["slide_id"]} (layout=#{request["layout"]}):
    "#{request["prompt"]}"
    #{slide_context_line(deck, request["slide_id"])}
    The request applies to the whole slide.

    Return the complete replacement JSON object for this one slide.
    #{retry_block(retry)}
    """
  end

  # Anchor the edit in the deck's arc — the full deck is in the context
  # block, but small models miss it; say where this slide sits explicitly.
  defp slide_context_line(deck, slide_id) do
    slide = Enum.find(List.wrap(deck["slides"]), &(is_map(&1) and &1["id"] == slide_id))

    case slide do
      %{"kicker" => kicker} when is_binary(kicker) and kicker != "" ->
        "This slide sits in the section \"#{kicker}\" — keep the edit coherent with that " <>
          "section and the deck's overall arc.\n"

      _ ->
        ""
    end
  end

  # ----- Ops prompts (scoped edits emit operations, never slides) ----------------

  @doc false
  def ops_system_prompt do
    """
    You are a slide-deck edit agent for a presentation builder. You receive a
    deck (JSON), and one edit request scoped to a single named part of one
    slide. You respond with the OPERATIONS that perform the change — never
    with the slide itself.

    Respond with ONLY this JSON object. No prose, no markdown fences:
    {"ops": [ ... ]}

    Operations (parts are addressed by their app-assigned "id"):
    - {"op": "set_field", "field": "<name>", "value": <value>}
      sets a field on the slide itself
    - {"op": "set_field", "part": "<part id>", "field": "<name>", "value": <value>}
      sets a field on one list part
    - {"op": "delete_field", "field": "<name>"} / with "part" — removes a field
    - {"op": "replace_part", "part": "<part id>", "value": {<full replacement part>}}
    - {"op": "insert_part", "list": "points|steps|items", "after": "<part id>"|"start"|"end", "part": {<the new part>}}
    - {"op": "remove_part", "part": "<part id>"}
    - {"op": "move_part", "part": "<part id>", "after": "<part id>"|"start"|"end"}

    Rules:
    - Emit ONLY ops that change the requested target — nothing else on the
      slide may be touched, and a validator rejects out-of-scope ops.
    - Prefer the smallest ops that do the job (set one field over replacing
      a whole part).
    - Never set "id", "layout", or "image" — they are app-managed.
    - Values must stay within the design system below.
    - Match the deck's writing voice.

    #{Decks.schema_prompt()}
    """
  end

  @doc false
  def ops_user_prompt(deck, request, retry) do
    """
    Edit request for the slide with id=#{request["slide_id"]} (layout=#{request["layout"]}):
    "#{request["prompt"]}"
    #{slide_context_line(deck, request["slide_id"])}
    #{target_description(request["target"])}

    Return {"ops": [...]} performing exactly this change.
    #{retry_block(retry)}
    """
  end

  defp target_description(%{"kind" => "field", "field" => field}) do
    "Your ops may change ONLY the \"#{field}\" field of the slide itself (no \"part\" key)."
  end

  defp target_description(%{"kind" => "part", "part" => part}) do
    "Your ops may change ONLY the part with id \"#{part}\" (set/delete its fields, or replace_part it)."
  end

  defp target_description(%{"kind" => "part_field", "part" => part, "field" => field}) do
    "Your ops may change ONLY the \"#{field}\" field of the part with id \"#{part}\"."
  end

  defp target_description(_target), do: "Change only what the request asks for."

  @doc false
  def create_system_prompt do
    """
    You are a presentation author for a slide-deck builder. You receive a talk
    description plus theme/voice/length choices, and you return a COMPLETE deck
    as one JSON object.

    Rules:
    - Respond with ONLY the deck JSON object. No prose, no markdown fences.
    - Stay strictly within the design system described below — a validator
      rejects anything outside it.
    - Give every slide an "id" (short, unique, e.g. "s0", "s1", ...).
    - Structure like a real talk: open with a "title" slide, build the story,
      close strong. Vary layouts — bullets for lists, points for grids of
      ideas, flow for processes, table for comparisons, statement (sometimes
      with tone "accent") for the big beats, faq if questions fit.
    - Kickers ("§ 1 · TOPIC" style) keep the audience oriented — use them.
    - Add speaker "notes" to the slides where delivery guidance helps.
    - Hit the requested slide count within ±2 slides.

    Quality bar — what separates a good deck from filler:
    - Slides are not essays: short, punchy lines; at most ~5 bullets on a
      slide; one idea per slide. The narration belongs in "notes".
    - Be concrete and specific: real numbers, named examples, sharp claims —
      never generic filler like "in today's fast-paced world".
    - Use ==accent== marks on THE key phrase of a slide (sparingly — one or
      two per slide), **strong** for emphasis, `code` for identifiers.
    - Make the deck tell a story: a hook up front, rising stakes, a payoff.
      Section kickers should trace that arc.

    #{Decks.schema_prompt()}
    """
  end

  @doc false
  def create_user_prompt(request, retry) do
    """
    Create a presentation.

    Theme: #{request["theme"]} (set "theme" and use accent "#{request["accent"]}")
    Voice / audience: #{request["voice"]}
    Talk length: #{request["minutes"]} minutes — aim for #{request["target_slides"]} slides (±2).

    What the talk is about, and the main points to cover:
    #{request["prompt"]}
    #{research_block(request)}
    Return the complete deck JSON object.
    #{retry_block(retry)}
    """
  end

  # Author-supplied grounding material, extracted server-side from their
  # uploaded document. This is the difference between a deck of concrete
  # claims and a deck of generic filler — the model is told to mine it.
  defp research_block(request) do
    case request["research"] do
      text when is_binary(text) and text != "" ->
        """

        The author uploaded research material ("#{request["research_filename"] || "document"}").
        Ground the deck in it: pull the concrete facts, numbers, names, and quotes from this
        material instead of inventing generic content. Where a specific source or figure
        carries a slide, a "footnote" is a good place to attribute it.

        <research>
        #{text}
        </research>
        """

      _ ->
        ""
    end
  end

  defp retry_block(nil), do: ""

  defp retry_block(%{errors: errors} = retry) do
    previous =
      case retry[:previous] do
        %{} = map ->
          """
          Your previous attempt was:
          #{Jason.encode!(map)}
          """

        _ ->
          ""
      end

    """

    #{previous}It was rejected by the validator with these errors:
    #{Enum.map_join(errors, "\n", &("- " <> &1))}
    Fix ONLY what the errors require and return the corrected JSON.
    """
  end

  # The model is asked for bare JSON, but be lenient: try the whole reply,
  # then each fenced block, then the outermost brace span. Among candidates
  # that decode to an object, the LARGEST wins — a reply that narrates with
  # a small example object before the real payload must not have its example
  # parsed as the answer.
  @doc false
  def extract_json(text) do
    text = String.trim(text)

    candidates = [text] ++ fenced_blocks(text) ++ brace_span(text)

    decoded = Enum.map(candidates, &{&1, Jason.decode(&1)})

    objects =
      for {source, {:ok, %{} = object}} <- decoded, do: {byte_size(source), object}

    cond do
      objects != [] ->
        {_size, object} = Enum.max_by(objects, &elem(&1, 0))
        {:ok, object}

      Enum.any?(decoded, &match?({_, {:ok, _}}, &1)) ->
        {:error, :not_an_object}

      true ->
        {:error, {:invalid_json, first_decode_error(decoded)}}
    end
  end

  defp first_decode_error(decoded) do
    Enum.find_value(decoded, "no JSON found", fn
      {_source, {:error, err}} -> Exception.message(err)
      _ -> nil
    end)
  end

  defp fenced_blocks(text) do
    ~r/```(?:json)?\s*(.*?)```/s
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [inner] -> String.trim(inner) end)
  end

  defp brace_span(text) do
    with first when first != nil <- first_index(text, "{"),
         last when last != nil and last > first <- last_index(text, "}") do
      [binary_part(text, first, last - first + 1)]
    else
      _ -> []
    end
  end

  defp first_index(text, char) do
    case :binary.match(text, char) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end

  defp last_index(text, char) do
    case :binary.matches(text, char) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  @doc false
  def fetch_api_key do
    case config(:agent_api_key, nil) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp config(key, default) do
    Application.get_env(:uitstalling, key, default)
  end
end
