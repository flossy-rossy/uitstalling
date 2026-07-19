defmodule Uitstalling.Decks.Op.ReplacePart do
  @moduledoc """
  Replace a part's content wholesale, keeping its id — an incoming `"id"`
  inside `value` is discarded on apply.
  """

  @derive Jason.Encoder
  @enforce_keys [:slide, :part, :value]
  defstruct [:slide, :part, :value]
end
