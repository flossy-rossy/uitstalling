defmodule Uitstalling.Decks.Op.InsertPart do
  @moduledoc """
  Insert a new part into one of the slide's part lists. `after` is a part id,
  `"start"`, or `"end"` (default). The app mints the part's id on apply — an
  incoming `"id"` inside `part` is discarded.
  """

  @derive Jason.Encoder
  @enforce_keys [:slide, :list, :part]
  defstruct [:slide, :list, :part, after: "end"]
end
