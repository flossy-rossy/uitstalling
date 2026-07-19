defmodule Uitstalling.Decks.Op.SetField do
  @moduledoc """
  Set `field` on a slide (`part: nil`) or on one of its parts (`part: "p2"`).
  The value's validity is the design system's problem — `Decks.parse/1` runs
  after every batch.
  """

  @derive Jason.Encoder
  @enforce_keys [:slide, :field, :value]
  defstruct [:slide, :part, :field, :value]
end
