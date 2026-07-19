defmodule Uitstalling.HTTP do
  @moduledoc """
  Shared Req options for provider calls (text agents, image generation).

  Req's default retry (`:safe_transient`) only covers GET/HEAD — our POSTs
  get zero retries out of the box, so a dropped keep-alive connection
  (`%Req.TransportError{reason: :closed}`) was failing requests that a
  single immediate retry would have saved. This opts POSTs into retrying:

  - transport errors that fail fast: `:closed`, `:econnrefused`
  - HTTP statuses the server itself calls transient: 408, 429 (Retry-After
    respected), 500/502/503/504, and 529 (Anthropic's overloaded — missing
    from Req's default list)

  Deliberately NOT retried: `:timeout` — our receive timeouts run minutes,
  and replaying them serially would wedge a deck's worker for ~15 minutes;
  a timeout should fail visibly instead. And any other 4xx: the request is
  wrong, retrying won't fix it.

  Tests inject `config :uitstalling, :req_options` (a `Req.Test` plug +
  zero retry delay); it merges between our defaults and the call site's
  options.
  """

  @transient_statuses [408, 429, 500, 502, 503, 504, 529]
  @transient_reasons [:closed, :econnrefused]

  @doc "Req options for a provider POST: retries + test injection + `overrides`."
  def options(overrides) do
    [retry: &transient?/2, max_retries: 2, retry_log_level: :warning]
    |> Keyword.merge(Application.get_env(:uitstalling, :req_options, []))
    |> Keyword.merge(overrides)
  end

  defp transient?(_request, %Req.Response{status: status}),
    do: status in @transient_statuses

  defp transient?(_request, %Req.TransportError{reason: reason}),
    do: reason in @transient_reasons

  defp transient?(_request, _other), do: false
end
