defmodule Uitstalling.Accounts do
  @moduledoc """
  Users + the closed-beta authorship gate.

  During the closed beta, only allowlisted emails (`:allowed_emails` config)
  may register a passkey and author decks. An empty allowlist means open
  (the future public mode). Presenting is always public — no user needed.
  """

  alias Uitstalling.Accounts.User
  alias Uitstalling.Repo

  def get_user(nil), do: nil
  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email), do: Repo.get_by(User, email: email)

  @doc "Find or create a registered user for an allowlisted email. Errors otherwise."
  def register_user(email, name \\ nil) do
    email = email |> to_string() |> String.trim() |> String.downcase()

    cond do
      not allowed_email?(email) ->
        {:error, :not_allowed}

      user = get_user_by_email(email) ->
        {:ok, user}

      true ->
        {:ok, Repo.insert!(%User{email: email, name: name, anonymous: false})}
    end
  end

  @doc "Whether an email may register/author (allowlist; empty list = open)."
  def allowed_email?(email) when is_binary(email) do
    case allowed_emails() do
      [] -> true
      list -> String.downcase(email) in list
    end
  end

  def allowed_email?(_), do: false

  @doc "Whether a user may create/edit decks: registered and still allowlisted."
  def can_author?(nil), do: false
  def can_author?(%User{anonymous: true}), do: false
  def can_author?(%User{email: email}) when is_binary(email), do: allowed_email?(email)
  def can_author?(_), do: false

  defp allowed_emails do
    Application.get_env(:uitstalling, :allowed_emails, [])
    |> Enum.map(&String.downcase/1)
  end
end
