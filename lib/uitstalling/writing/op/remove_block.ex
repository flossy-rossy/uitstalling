defmodule Uitstalling.Writing.Op.RemoveBlock do
  @moduledoc "Remove the block with id `block`."

  @derive Jason.Encoder
  @enforce_keys [:block]
  defstruct [:block]
end
