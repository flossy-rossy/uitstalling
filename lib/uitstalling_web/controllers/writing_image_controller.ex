defmodule UitstallingWeb.WritingImageController do
  @moduledoc """
  Serves writing images (character portraits, sketches) — decrypted on the
  way out, owner-only. Unlike `/a/:id` (public, like the decks that embed
  those assets), nothing under /write is ever served to anyone else.
  """

  use UitstallingWeb, :controller

  alias Uitstalling.Accounts
  alias Uitstalling.Writing

  def show(conn, %{"project_id" => project_id, "id" => image_id}) do
    user = conn.assigns.current_user

    with true <- Accounts.can_author?(user) and Writing.owned_by?(project_id, user.id),
         project = Writing.get_project!(project_id, user.id),
         {content_type, bytes} <- Writing.get_image(project, image_id) do
      conn
      |> put_resp_content_type(content_type)
      # Immutable per id (replacing a portrait mints a new id), but private:
      # only this browser may cache it.
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end
end
