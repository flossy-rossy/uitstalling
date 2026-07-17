defmodule Uitstalling.Decks.Agent.Claude do
  @moduledoc """
  Real agent: one Messages API call per request (Anthropic wire format).

  Prompt layout follows the caching rules: the stable design-system block goes
  first in `system` with a cache breakpoint; everything volatile (deck JSON,
  the request, retry errors) goes in the user turn. Configured entirely via env:

    AGENT_API_KEY  — provider API key (required)
    AGENT_MODEL    — model id, per-request parameter (default claude-haiku-4-5)
    AGENT_BASE_URL — Anthropic-compatible endpoint (default https://api.anthropic.com;
                     Z.ai GLM works via https://api.z.ai/api/anthropic)
  """

  @behaviour Uitstalling.Decks.Agent

  require Logger

  alias Uitstalling.Decks

  @impl true
  def generate_slide(deck, request, errors) do
    with {:ok, api_key} <- fetch_api_key(),
         {:ok, text} <-
           call_api(api_key, edit_system_prompt(), edit_user_prompt(deck, request, errors), 4096) do
      extract_json(text)
    end
  end

  @impl true
  def generate_deck(request, errors) do
    with {:ok, api_key} <- fetch_api_key(),
         {:ok, text} <-
           call_api(api_key, create_system_prompt(), create_user_prompt(request, errors), 16_000) do
      extract_json(text)
    end
  end

  defp call_api(api_key, system, user, max_tokens) do
    body = %{
      model: config(:agent_model, "claude-haiku-4-5"),
      max_tokens: max_tokens,
      system: [
        %{type: "text", text: system, cache_control: %{type: "ephemeral"}}
      ],
      messages: [%{role: "user", content: user}]
    }

    url =
      config(:agent_base_url, "https://api.anthropic.com")
      |> String.trim_trailing("/")
      |> Kernel.<>("/v1/messages")

    case Req.post(url,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"}
           ],
           receive_timeout: 300_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"content" => content} = resp}} ->
        case resp["stop_reason"] do
          "refusal" ->
            {:error, :refused}

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
      change. Respect the "block" scope when one is given.
    - Match the deck's writing voice.

    #{Decks.schema_prompt()}
    """
  end

  @doc false
  def edit_user_prompt(deck, request, errors) do
    voice = deck["voice"] || "punchy, technical, confident"

    scope =
      if request["block"],
        do: "Change ONLY the \"#{request["block"]}\" part of the slide.",
        else: "The request applies to the whole slide."

    """
    Deck voice: #{voice}

    Full deck for context:
    #{Jason.encode!(deck)}

    Edit request for slide index #{request["slide_index"]} (id=#{request["slide_id"]}, layout=#{request["layout"]}):
    "#{request["prompt"]}"

    #{scope}

    Return the complete replacement JSON object for this one slide.
    #{retry_block(errors)}
    """
  end

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

    #{Decks.schema_prompt()}
    """
  end

  @doc false
  def create_user_prompt(request, errors) do
    """
    Create a presentation.

    Theme: #{request["theme"]} (set "theme" and use accent "#{request["accent"]}")
    Voice / audience: #{request["voice"]}
    Talk length: #{request["minutes"]} minutes — aim for #{request["target_slides"]} slides (±2).

    What the talk is about, and the main points to cover:
    #{request["prompt"]}

    Return the complete deck JSON object.
    #{retry_block(errors)}
    """
  end

  defp retry_block([]), do: ""

  defp retry_block(errors) do
    """

    Your previous attempt was rejected by the validator with these errors.
    Fix them and return the corrected JSON:
    #{Enum.map_join(errors, "\n", &("- " <> &1))}
    """
  end

  # The model is asked for bare JSON, but be lenient about markdown fences.
  @doc false
  def extract_json(text) do
    text = String.trim(text)

    text =
      case Regex.run(~r/```(?:json)?\s*(\{.*\})\s*```/s, text) do
        [_, inner] -> inner
        nil -> text
      end

    case Jason.decode(text) do
      {:ok, %{} = object} -> {:ok, object}
      {:ok, _other} -> {:error, :not_an_object}
      {:error, err} -> {:error, {:invalid_json, Exception.message(err)}}
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
