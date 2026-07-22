defmodule Uitstalling.Writing.Op.DeleteField do
  @moduledoc "Delete an optional `field` from the block with id `block`."

  @derive Jason.Encoder
  @enforce_keys [:block, :field]
  defstruct [:block, :field]
end
