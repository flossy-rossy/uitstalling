defmodule Uitstalling.Decks.Slide do
  @moduledoc """
  One slide. `fields` holds the layout-specific data (string-keyed, straight
  from the JSON boundary), already validated against the layout's spec in
  `Uitstalling.Decks`.
  """

  defstruct [:id, :layout, :tone, :size, :kicker, :footnote, :notes, fields: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          layout: String.t(),
          tone: String.t(),
          size: String.t(),
          kicker: String.t() | nil,
          footnote: String.t() | nil,
          notes: String.t() | nil,
          fields: %{String.t() => term()}
        }
end
