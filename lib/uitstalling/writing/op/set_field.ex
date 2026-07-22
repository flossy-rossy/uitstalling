defmodule Uitstalling.Writing.Op.SetField do
  @moduledoc """
  Set `field` on the block with id `block`. Setting `"type"` retypes the
  block — leftover fields from the old type fail validation, so a retype
  batch pairs this with `delete_field` ops. Value validity is the schema's
  problem: `Writing.parse/2` runs after every batch.
  """

  @derive Jason.Encoder
  @enforce_keys [:block, :field, :value]
  defstruct [:block, :field, :value]
end
