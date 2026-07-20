defmodule UitstallingWeb.DeckPdfController do
  @moduledoc """
  PDF export. `GET /deck/:id/print` is the dead render the app's own
  headless Chrome prints — public, like presenting. `GET /deck/:id/pdf`
  runs the print and sends the file as a download.
  """

  use UitstallingWeb, :controller

  require Logger

  alias Uitstalling.Decks

  plug :load_deck when action in [:print, :download]

  def print(conn, _params) do
    conn
    |> put_root_layout(false)
    |> render(:print, deck: conn.assigns.deck)
  end

  def download(conn, %{"id" => deck_id}) do
    case Decks.Pdf.impl().render(deck_id) do
      {:ok, pdf} ->
        send_download(conn, {:binary, pdf},
          filename: "#{Decks.deck_slug(deck_id)}.pdf",
          content_type: "application/pdf"
        )

      {:error, reason} ->
        Logger.error("PDF export failed for deck #{deck_id}: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Couldn't produce the PDF — try again in a moment")
        |> redirect(to: ~p"/deck/#{deck_id}")
    end
  end

  # Serve a background-generated PDF parked under a one-shot token — the
  # response is instant, so the browser's download manager takes it cleanly.
  def fetch(conn, %{"token" => token}) do
    case Decks.PdfStore.take(token) do
      {:ok, pdf, filename} ->
        send_download(conn, {:binary, pdf}, filename: filename, content_type: "application/pdf")

      :error ->
        send_resp(conn, 404, "that download has expired — export it again from the deck")
    end
  end

  # Same leniency as DeckLive.mount_deck: a stored deck that stopped
  # validating must 404/degrade, not 500.
  defp load_deck(conn, _opts) do
    deck_id = conn.params["id"]

    with true <- Decks.exists?(deck_id),
         {:ok, deck} <- Decks.parse(Decks.load_raw!(deck_id)) do
      assign(conn, :deck, deck)
    else
      _ -> conn |> send_resp(404, "no such presentation") |> halt()
    end
  end
end
