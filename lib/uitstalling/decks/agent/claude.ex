defmodule Uitstalling.Decks.Agent.Claude do
  @moduledoc """
  Wire client for Anthropic-shaped providers: one Messages API call per
  request. All prompt/context assembly lives in `Agent.Context` — this module
  only packs those strings into the Anthropic request shape.

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

  alias Uitstalling.Decks.Agent
  alias Uitstalling.Decks.Agent.Context

  @impl true
  def generate_slide(deck, request, retry) do
    system = [Context.edit_system_prompt(), Context.edit_context_prompt(deck)]

    with {:ok, api_key} <- Agent.fetch_api_key(),
         {:ok, text} <-
           call_api(api_key, system, Context.edit_user_prompt(deck, request, retry), 4096) do
      Context.extract_json(text)
    end
  end

  @impl true
  def generate_ops(deck, request, retry) do
    system = [Context.ops_system_prompt(), Context.edit_context_prompt(deck)]

    with {:ok, api_key} <- Agent.fetch_api_key(),
         {:ok, text} <-
           call_api(api_key, system, Context.ops_user_prompt(deck, request, retry), 2048) do
      Context.extract_json(text)
    end
  end

  @impl true
  def generate_deck(request, retry) do
    with {:ok, api_key} <- Agent.fetch_api_key(),
         {:ok, text} <-
           call_api(
             api_key,
             [Context.create_system_prompt()],
             Context.create_user_prompt(request, retry),
             24_000
           ) do
      Context.extract_json(text)
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

  defp config(key, default) do
    Application.get_env(:uitstalling, key, default)
  end
end
