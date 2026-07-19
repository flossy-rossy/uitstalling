defmodule Uitstalling.Decks.Op.RemovePart do
  @moduledoc "Remove the part with this id from whichever list holds it."

  @derive Jason.Encoder
  @enforce_keys [:slide, :part]
  defstruct [:slide, :part]
end
