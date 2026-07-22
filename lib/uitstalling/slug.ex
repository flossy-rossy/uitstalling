defmodule Uitstalling.Slug do
  @moduledoc """
  URL slugs for public pages: `/:user_slug` and `/:user_slug/:deck_slug`.
  ASCII-only, lowercase, hyphen-separated, bounded — and never one of the
  app's own top-level route segments (the user-slug route is a catch-all).
  """

  # Top-level path segments the router owns — a user slug must never shadow
  # them. Keep in sync with the router.
  @reserved ~w(new auth deck dev a pdf write assets fonts images favicon.ico robots.txt)

  @max_length 60

  def reserved, do: @reserved

  @doc "Slugify freeform text; empty result stays empty (caller picks a fallback)."
  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.split(~r/[\s-]+/, trim: true)
    |> Enum.join("-")
    |> String.slice(0, @max_length)
  end

  def slugify(_other), do: ""

  @doc """
  First available slug for `text`: the base, else base-2, base-3, …
  `taken?` decides availability; reserved segments always count as taken.
  `fallback` covers text that slugifies to nothing (emoji names, empty).
  """
  def unique(text, fallback, taken?) when is_function(taken?, 1) do
    base =
      case slugify(text) do
        "" -> fallback
        slug -> slug
      end

    Stream.concat([base], Stream.map(2..1000, &"#{base}-#{&1}"))
    |> Enum.find(fn candidate ->
      candidate not in @reserved and not taken?.(candidate)
    end)
  end
end
