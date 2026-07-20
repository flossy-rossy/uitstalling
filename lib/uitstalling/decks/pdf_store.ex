defmodule Uitstalling.Decks.PdfStore do
  @moduledoc """
  Short-lived handoff for generated PDFs. The LiveView renders the PDF in a
  background task, parks the bytes here under a random token, and the
  browser collects them from `GET /pdf/:token` — an instant response that
  lands in the browser's download manager, instead of a page navigation
  that hangs on Chrome for seconds.

  One-shot and self-expiring: a token serves exactly once, and unclaimed
  entries are swept after five minutes.
  """

  use GenServer

  @table __MODULE__
  @ttl :timer.minutes(5)
  @sweep_every :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Park a PDF; returns the one-shot download token."
  def put(pdf, filename) when is_binary(pdf) and is_binary(filename) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    :ets.insert(@table, {token, pdf, filename, System.monotonic_time(:millisecond)})
    token
  end

  @doc "Claim (and remove) a parked PDF."
  def take(token) when is_binary(token) do
    case :ets.take(@table, token) do
      [{^token, pdf, filename, _at}] -> {:ok, pdf, filename}
      [] -> :error
    end
  end

  def take(_token), do: :error

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set])
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @ttl
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end
end
