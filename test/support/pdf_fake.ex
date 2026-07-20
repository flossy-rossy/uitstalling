defmodule Uitstalling.Decks.Pdf.Fake do
  @moduledoc """
  Stands in for the Chrome round-trip (tests run no server, so the real
  renderer would have nothing to print). Deck ids starting with "pdf-fail"
  error, driving the controller's failure path.
  """

  @behaviour Uitstalling.Decks.Pdf

  @impl true
  def render("pdf-fail" <> _rest), do: {:error, :chrome_crashed}
  def render(_deck_id), do: {:ok, "%PDF-1.4 fake"}
end
