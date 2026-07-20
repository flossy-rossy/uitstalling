defmodule Uitstalling.Assets.Generator.OpenRouter do
  @moduledoc """
  Image generation via OpenRouter's unified Image API — one key, 30+ models
  (FLUX, Gemini image, gpt-image, Recraft, Seedream...), model chosen per
  request. Synchronous: POST /v1/images returns base64 bytes. Configured via:

    IMAGE_API_KEY  — falls back to AGENT_API_KEY (same key when the text agent
                     already talks to OpenRouter)
    IMAGE_MODEL    — e.g. "black-forest-labs/flux.2-pro" (default seedream-4.5)
    IMAGE_BASE_URL — default https://openrouter.ai/api/v1
  """

  @behaviour Uitstalling.Assets.Generator

  require Logger

  @impl true
  def generate(prompt, opts \\ []) do
    with {:ok, api_key} <- fetch_api_key() do
      body =
        %{
          model: opts[:model] || config(:image_model, Uitstalling.Assets.ImageModels.default()),
          prompt: prompt,
          # Slides are 16:9 frames; webp/png both fine, png is universally safe
          aspect_ratio: "16:9",
          output_format: "png",
          n: 1
        }
        |> put_reference(opts[:reference])

      url =
        config(:image_base_url, "https://openrouter.ai/api/v1")
        |> String.trim_trailing("/")
        |> Kernel.<>("/images")

      # This bounds how long a DeckWorker blocks on one generation — a hung
      # provider fails the request instead of wedging the deck's queue.
      timeout = Application.get_env(:uitstalling, :image_gen_timeout, 120_000)

      case Req.post(
             url,
             Uitstalling.HTTP.options(
               json: body,
               auth: {:bearer, api_key},
               receive_timeout: timeout
             )
           ) do
        {:ok, %Req.Response{status: 200, body: %{"data" => [%{"b64_json" => b64} = image | _]}}} ->
          case Base.decode64(b64) do
            {:ok, bytes} ->
              {:ok, %{bytes: bytes, content_type: image["media_type"] || "image/png"}}

            :error ->
              {:error, :bad_image_payload}
          end

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          Logger.warning("image API error #{status} — POST #{url}: #{inspect(resp_body)}")
          {:error, {:api_error, status, resp_body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  # Image-to-image: the reference rides along as a base64 data URL in
  # OpenRouter's input_references (supported per-model; unsupported models
  # simply error, which surfaces as a failed request).
  defp put_reference(body, nil), do: body

  defp put_reference(body, {bytes, content_type}) do
    Map.put(body, :input_references, [
      %{
        type: "image_url",
        image_url: %{url: "data:#{content_type};base64,#{Base.encode64(bytes)}"}
      }
    ])
  end

  defp fetch_api_key do
    case config(:image_api_key, nil) || config(:agent_api_key, nil) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_image_api_key}
    end
  end

  defp config(key, default), do: Application.get_env(:uitstalling, key, default)
end
