defmodule Uitstalling.Decks.Agent do
  @moduledoc """
  The model behind slide generation. Two jobs, same contract: given context,
  a request, and any validation errors from a previous attempt, return raw
  JSON the pipeline validates before persisting.

  Swappable via `config :uitstalling, :deck_agent` — tests use
  `Uitstalling.Decks.Agent.Fake`.
  """

  @doc "Replacement for one slide of an existing deck."
  @callback generate_slide(deck :: map(), request :: map(), errors :: [String.t()]) ::
              {:ok, map()} | {:error, term()}

  @doc "A whole new deck from a topic prompt + theme/voice/length choices."
  @callback generate_deck(request :: map(), errors :: [String.t()]) ::
              {:ok, map()} | {:error, term()}

  def impl do
    Application.get_env(:uitstalling, :deck_agent, Uitstalling.Decks.Agent.Claude)
  end
end
