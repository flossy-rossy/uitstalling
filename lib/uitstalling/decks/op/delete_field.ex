defmodule Uitstalling.Decks.Op.DeleteField do
  @moduledoc "Delete `field` from a slide (`part: nil`) or from one of its parts."

  @derive Jason.Encoder
  @enforce_keys [:slide, :field]
  defstruct [:slide, :part, :field]
end
