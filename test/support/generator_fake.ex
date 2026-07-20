defmodule Uitstalling.Assets.Generator.Fake do
  @moduledoc """
  Deterministic test image generator: returns a minimal PNG whose bytes
  embed the prompt. Prompts starting with "FAIL:" return an error.
  """

  @behaviour Uitstalling.Assets.Generator

  @png_header <<0x89, "PNG\r\n", 0x1A, "\n">>

  @impl true
  def generate(prompt, opts \\ [])

  def generate("FAIL:" <> _rest, _opts), do: {:error, :fake_generation_failed}

  # A provider that stalls until the configured HTTP timeout, then fails the
  # way the real client would — exercises the timeout/cancel paths.
  def generate("SLOW:" <> _rest, _opts) do
    Process.sleep(Application.get_env(:uitstalling, :image_gen_timeout, 500))
    {:error, {:http_error, :timeout}}
  end

  # The chosen model (and whether a reference image arrived) ride along in
  # the bytes so tests can assert on them.
  def generate(prompt, opts) do
    ref = if opts[:reference], do: "ref|", else: ""
    {:ok, %{bytes: @png_header <> "#{opts[:model]}|" <> ref <> prompt, content_type: "image/png"}}
  end
end
