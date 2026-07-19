defmodule Uitstalling.Decks.Agent.OpenAI do
  @moduledoc """
  Agent client for OpenAI-shaped providers (OpenRouter, most cheap-model
  aggregators): `POST <base>/chat/completions` with Bearer auth. Same prompts
  and validate-retry contract as the Anthropic-shaped client — only the wire
  format differs. Select with AGENT_API_FORMAT=openai.

    AGENT_API_KEY  — provider API key (required)
    AGENT_MODEL    — e.g. "z-ai/glm-4.6" on OpenRouter
    AGENT_BASE_URL — default https://openrouter.ai/api/v1
    AGENT_APP_URL  — optional; sent as HTTP-Referer so OpenRouter attributes
                     traffic to the app (X-Title is always sent)
  """

  @behaviour Uitstalling.Decks.Agent

  require Logger

  alias Uitstalling.Decks.Agent.Claude

  @impl true
  def generate_slide(deck, request, retry) do
    system = Claude.edit_system_prompt() <> "\n" <> Claude.edit_context_prompt(deck)

    with {:ok, api_key} <- Claude.fetch_api_key(),
         {:ok, text} <-
           call_api(api_key, system, Claude.edit_user_prompt(request, retry), max_tokens: 4096) do
      Claude.extract_json(text)
    end
  end

  @impl true
  def generate_ops(deck, request, retry) do
    system = Claude.ops_system_prompt() <> "\n" <> Claude.edit_context_prompt(deck)

    with {:ok, api_key} <- Claude.fetch_api_key(),
         {:ok, text} <-
           call_api(api_key, system, Claude.ops_user_prompt(request, retry), max_tokens: 2048) do
      Claude.extract_json(text)
    end
  end

  @impl true
  def generate_deck(request, retry) do
    # Whole-deck generation is the hard task: turn on reasoning (OpenRouter
    # normalizes this across models, ignores it where unsupported) and give
    # the budget headroom — reasoning tokens count against max_tokens.
    with {:ok, api_key} <- Claude.fetch_api_key(),
         {:ok, text} <-
           call_api(
             api_key,
             Claude.create_system_prompt(),
             Claude.create_user_prompt(request, retry),
             max_tokens: 32_000,
             reasoning: true
           ) do
      Claude.extract_json(text)
    end
  end

  defp call_api(api_key, system, user, opts) do
    body = %{
      model: Application.get_env(:uitstalling, :agent_model, "z-ai/glm-4.6"),
      max_tokens: Keyword.fetch!(opts, :max_tokens),
      messages: [
        %{role: "system", content: system},
        %{role: "user", content: user}
      ]
    }

    body = if opts[:reasoning], do: Map.put(body, :reasoning, %{enabled: true}), else: body

    url =
      Application.get_env(:uitstalling, :agent_base_url, "https://openrouter.ai/api/v1")
      |> String.trim_trailing("/")
      |> Kernel.<>("/chat/completions")

    case Req.post(url,
           json: body,
           auth: {:bearer, api_key},
           headers: attribution_headers(),
           receive_timeout: 300_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"choices" => [choice | _]}}} ->
        # "length" = the reply (or its reasoning) exhausted max_tokens —
        # content is a fragment or empty; report that instead of letting it
        # surface as a misleading invalid-JSON error.
        if choice["finish_reason"] == "length",
          do: {:error, :truncated},
          else: {:ok, choice["message"]["content"] || ""}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.warning(
          "agent API error #{status} — POST #{url} model=#{body.model}: #{inspect(resp_body)}"
        )

        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # OpenRouter-specific (harmlessly ignored elsewhere): identifies the app in
  # their rankings/analytics. HTTP-Referer only when an app URL is configured.
  defp attribution_headers do
    base = [{"X-Title", "uitstalling"}]

    case Application.get_env(:uitstalling, :agent_app_url) do
      url when is_binary(url) and url != "" -> [{"HTTP-Referer", url} | base]
      _ -> base
    end
  end
end
