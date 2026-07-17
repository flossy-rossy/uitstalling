defmodule Uitstalling.Decks.Deck do
  @moduledoc """
  A validated slide deck. Only ever constructed by `Uitstalling.Decks.parse/1`
  — if you're holding a `%Deck{}`, every slide in it passed validation and is
  safe to hand to the renderer.
  """

  defstruct [:title, :accent, :theme, :voice, slides: []]

  @type t :: %__MODULE__{
          title: String.t(),
          accent: String.t(),
          theme: String.t(),
          voice: String.t() | nil,
          slides: [Uitstalling.Decks.Slide.t()]
        }
end
