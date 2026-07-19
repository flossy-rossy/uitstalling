defmodule Uitstalling.Decks.Op.MovePart do
  @moduledoc """
  Reposition a part within its list. `after` is a part id, `"start"`, or
  `"end"`.
  """

  @derive Jason.Encoder
  @enforce_keys [:slide, :part, :after]
  defstruct [:slide, :part, :after]
end
