defmodule Uitstalling.Decks.Pdf do
  @moduledoc """
  Prints a deck to PDF for download — the offline backup of a presentation.

  Points the app's own headless Chrome (ChromicPDF) at the dead print view
  `/deck/:id/print`, which reuses the one AST→markup path restyled to a
  16:9 page per slide. Live-only content degrades in that view (video
  becomes a placeholder card), not here. Chrome fetches over loopback, so
  CSS and asset URLs resolve exactly as they do for a browser.

  Behaviour + `impl/0` so tests can stub the Chrome round-trip, same as
  `Decks.Agent` and `Assets.Generator`.
  """

  @callback render(String.t()) :: {:ok, binary()} | {:error, term()}

  @behaviour __MODULE__

  # Classic 16:9 presentation page, in inches (1280×720 CSS px at 96dpi).
  @page_width 13.333
  @page_height 7.5

  # Cold Chrome start (on_demand) + up to 40 slides of layout and images.
  @timeout :timer.seconds(60)

  def impl, do: Application.get_env(:uitstalling, :pdf_renderer, __MODULE__)

  @impl true
  def render(deck_id) do
    result =
      ChromicPDF.print_to_pdf({:url, print_url(deck_id)},
        timeout: @timeout,
        print_to_pdf: %{
          paperWidth: @page_width,
          paperHeight: @page_height,
          marginTop: 0,
          marginBottom: 0,
          marginLeft: 0,
          marginRight: 0,
          printBackground: true
        }
      )

    with {:ok, base64} <- result, do: {:ok, Base.decode64!(base64)}
  catch
    # A wedged Chrome exits the pool call (timeout/noproc) — a failed
    # download must not take the caller down with it.
    :exit, reason -> {:error, reason}
  end

  # Loopback, not the public URL: no TLS/DNS round-trip, and it works before
  # a deck's host is even reachable from outside (dev, fresh deploys).
  defp print_url(deck_id) do
    port = UitstallingWeb.Endpoint.config(:http)[:port]
    "http://localhost:#{port}/deck/#{deck_id}/print"
  end
end
