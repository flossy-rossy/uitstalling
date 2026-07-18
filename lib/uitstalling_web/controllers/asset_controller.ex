defmodule UitstallingWeb.AssetController do
  @moduledoc """
  Serves stored assets by id: `GET /a/:asset_id`. Local storage streams the
  file; object storage 302-redirects to the (globally cached) bucket URL, so
  the app machine never proxies image bytes. Deck JSON only ever contains
  asset ids — the renderer builds these URLs, never the model.
  """

  use UitstallingWeb, :controller

  alias Uitstalling.Assets

  def show(conn, %{"id" => id}) do
    with %{status: "ready"} = asset <- Assets.get(id) do
      case Assets.serve(asset) do
        {:redirect, url} ->
          conn
          |> put_resp_header("cache-control", "public, max-age=3600")
          |> redirect(external: url)

        {:file, path, content_type} ->
          if File.exists?(path) do
            conn
            |> put_resp_content_type(content_type)
            |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
            |> send_file(200, path)
          else
            send_resp(conn, 404, "asset file missing")
          end
      end
    else
      _ -> send_resp(conn, 404, "no such asset")
    end
  end
end
