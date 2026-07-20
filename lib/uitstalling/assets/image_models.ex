defmodule Uitstalling.Assets.ImageModels do
  @moduledoc """
  The image-generation models offered in the UI — one place to add or retire
  a model.

  ORDER IS THE CONVENTION: cheapest first. The first entry is the default
  (what pipeline auto-generations use), and dropdowns render in file order so
  the cheapest always leads. Put a pricier model exactly where its cost ranks.
  """

  @models [
    %{id: "bytedance-seed/seedream-4.5", label: "Seedream 4.5 — fast & cheap"},
    %{id: "openai/gpt-image-2", label: "GPT Image 2 — pricier, higher fidelity"}
  ]

  def all, do: @models

  @doc "The cheapest model — first in the file by convention."
  def default, do: hd(@models).id

  def valid?(id), do: id in Enum.map(@models, & &1.id)

  @doc "`{label, id}` pairs for `options_for_select`, cheapest first."
  def options, do: Enum.map(@models, &{&1.label, &1.id})
end
