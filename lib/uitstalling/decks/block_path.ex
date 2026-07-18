defmodule Uitstalling.Decks.BlockPath do
  @moduledoc """
  Parsed addressing for parts of a slide. A path names a scalar key
  (`"heading"`), a list element (`"points.1"`), or a field inside a map-shaped
  list element (`"steps.2.body"`). One parser serves the mutation functions in
  `Uitstalling.Decks` and the LiveView, so a malformed client-supplied path is
  rejected in one place instead of crashing pattern matches downstream.
  """

  @type t ::
          {:key, String.t()}
          | {:item, String.t(), non_neg_integer()}
          | {:field, String.t(), non_neg_integer(), String.t()}

  @doc "Parse a path string. Returns `{:ok, t}` or `:error`."
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(path) when is_binary(path) do
    case String.split(path, ".") do
      [key] when key != "" ->
        {:ok, {:key, key}}

      [key, pos] when key != "" ->
        with {:ok, index} <- index(pos), do: {:ok, {:item, key, index}}

      [key, pos, sub] when key != "" and sub != "" ->
        with {:ok, index} <- index(pos), do: {:ok, {:field, key, index, sub}}

      _ ->
        :error
    end
  end

  def parse(_path), do: :error

  @doc "The list-or-scalar key a path is rooted at (`\"steps.2.body\"` -> `\"steps\"`)."
  @spec root(t()) :: String.t()
  def root({:key, key}), do: key
  def root({:item, key, _}), do: key
  def root({:field, key, _, _}), do: key

  defp index(pos) do
    case Integer.parse(pos) do
      {i, ""} when i >= 0 -> {:ok, i}
      _ -> :error
    end
  end
end
