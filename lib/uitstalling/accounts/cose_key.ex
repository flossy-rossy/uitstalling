defmodule Uitstalling.Accounts.CoseKey do
  @moduledoc """
  Ecto type for a COSE public key as returned by `wax_`.

  wax_ hands back the credential public key as a map with integer keys and
  binary/integer values, which doesn't round-trip through JSON. We persist it
  in a `:binary` column via `:erlang.term_to_binary/1`, and load it back with
  the `:safe` flag (the stored term contains no atoms).
  """
  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  def cast(map) when is_map(map), do: {:ok, map}
  def cast(_), do: :error

  @impl true
  def dump(map) when is_map(map), do: {:ok, :erlang.term_to_binary(map)}
  def dump(_), do: :error

  @impl true
  def load(bin) when is_binary(bin), do: {:ok, :erlang.binary_to_term(bin, [:safe])}
  def load(_), do: :error
end
