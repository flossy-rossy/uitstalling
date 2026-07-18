defmodule Uitstalling.Assets.Generator do
  @moduledoc """
  The model behind image generation. One job: prompt in, image bytes out.
  The caller (Uitstalling.Assets) sniffs, stores, and records the result —
  a generator only talks to a provider.

  Swappable via `config :uitstalling, :image_generator` — tests use
  `Uitstalling.Assets.Generator.Fake`.
  """

  @callback generate(prompt :: String.t()) ::
              {:ok, %{bytes: binary(), content_type: String.t()}} | {:error, term()}

  def impl do
    Application.get_env(:uitstalling, :image_generator, Uitstalling.Assets.Generator.OpenRouter)
  end
end
