defmodule Uitstalling.Writing.Op.MoveBlock do
  @moduledoc "Move the block with id `block` to sit after `after` (a block id, `\"start\"`, or `\"end\"`)."

  @derive Jason.Encoder
  @enforce_keys [:block]
  defstruct [:block, after: "end"]
end
