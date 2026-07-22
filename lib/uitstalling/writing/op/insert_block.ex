defmodule Uitstalling.Writing.Op.InsertBlock do
  @moduledoc """
  Insert a new block. `after` is a block id, `"start"`, or `"end"` (default).
  The app mints the block's id on apply — an incoming `"id"` from an
  untrusted batch is discarded at parse; an id already present on the struct
  is app-internal (an inverse restoring a removed block) and honored.
  """

  @derive Jason.Encoder
  @enforce_keys [:block]
  defstruct [:block, after: "end"]
end
