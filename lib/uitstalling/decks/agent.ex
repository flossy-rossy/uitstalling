defmodule Uitstalling.Decks.Agent do
  @moduledoc """
  The model behind slide generation. Two jobs, same contract: given context,
  a request, and — on retries — the previous attempt plus the validator
  errors that rejected it, return raw JSON the pipeline validates before
  persisting.

  `retry` is `nil` on the first attempt, then
  `%{errors: [String.t()], previous: map() | nil}` — `previous` is the
  rejected JSON object when one was extracted, so the model can patch
  instead of regenerating blind.

  Swappable via `config :uitstalling, :deck_agent` — tests use
  `Uitstalling.Decks.Agent.Fake`.
  """

  @type retry :: nil | %{errors: [String.t()], previous: map() | nil}

  @doc "Replacement for one slide of an existing deck (whole-slide rework)."
  @callback generate_slide(deck :: map(), request :: map(), retry()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Edit operations for a scoped change to one slide (see docs/edit-ops.md).
  `request["target"]` names the field/part the ops may touch. Returns the
  raw decoded reply — expected shape `{"ops": [...]}` — which the caller
  parses through `Uitstalling.Decks.Op` and enforces scope on.
  """
  @callback generate_ops(deck :: map(), request :: map(), retry()) ::
              {:ok, map()} | {:error, term()}

  @doc "A whole new deck from a topic prompt + theme/voice/length choices."
  @callback generate_deck(request :: map(), retry()) ::
              {:ok, map()} | {:error, term()}

  def impl do
    Application.get_env(:uitstalling, :deck_agent, Uitstalling.Decks.Agent.Claude)
  end
end
