defmodule Uitstalling.Accounts do
  @moduledoc """
  Users + the closed-beta authorship gate.

  During the closed beta, only allowlisted emails (`:allowed_emails` config)
  may register a passkey and author decks. An empty allowlist means open
  (the future public mode). Presenting is always public — no user needed.
  """

  import Ecto.Query

  alias Uitstalling.Accounts.User
  alias Uitstalling.Repo
  alias Uitstalling.Slug

  def get_user(nil), do: nil
  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email), do: Repo.get_by(User, email: email)

  @doc "The user whose public page lives at /:slug, or nil."
  def get_user_by_slug(slug) when is_binary(slug) and slug != "",
    do: Repo.get_by(User, slug: slug)

  def get_user_by_slug(_slug), do: nil

  @doc """
  Make sure the user has a public-page slug, minting one from their name
  (email local part as fallback) on first need. Once set it never changes —
  it's in people's shared links.
  """
  def ensure_slug!(%User{slug: slug} = user) when is_binary(slug) and slug != "", do: user

  def ensure_slug!(%User{} = user) do
    source = user.name || (user.email && hd(String.split(user.email, "@"))) || "presenter"

    slug =
      Slug.unique(source, "presenter", fn candidate ->
        Repo.exists?(from(u in User, where: u.slug == ^candidate))
      end)

    user |> Ecto.Changeset.change(slug: slug) |> Repo.update!()
  end

  @doc """
  Invite someone by email, setting the display name shown in their welcome
  splash — the signup form itself only asks for email. Run from a prod IEx:

      fly ssh console --pty -C "/app/bin/uitstalling remote"
      iex> Uitstalling.Accounts.invite_user("friend@example.com", "Sam")

  An invited row is also an authorization: the email may register a passkey
  regardless of the AUTHOR_EMAILS allowlist.
  """
  def invite_user(email, name) when is_binary(name) do
    email = normalize_email(email)

    case get_user_by_email(email) do
      nil ->
        Repo.insert!(%User{email: email, name: name, anonymous: false})

      user ->
        user |> Ecto.Changeset.change(name: name, anonymous: false) |> Repo.update!()
    end
    |> ensure_slug!()
  end

  @doc """
  Find or create a registered user at passkey registration. An existing row
  (an invite, or a returning user) always wins — its stored name is kept.
  Otherwise the email must pass the allowlist.
  """
  def register_user(email, name \\ nil) do
    email = normalize_email(email)

    cond do
      user = get_user_by_email(email) ->
        {:ok, ensure_slug!(user)}

      allowed_email?(email) ->
        {:ok, ensure_slug!(Repo.insert!(%User{email: email, name: name, anonymous: false}))}

      true ->
        {:error, :not_allowed}
    end
  end

  @doc "Whether an email may register via the allowlist (empty list = open)."
  def allowed_email?(email) when is_binary(email) do
    case allowed_emails() do
      [] -> true
      list -> String.downcase(email) in list
    end
  end

  def allowed_email?(_), do: false

  @doc """
  Whether a user may create/edit decks: any registered account (allowlisted
  signup or IEx invite). Revoke by deleting the user row.
  """
  def can_author?(%User{anonymous: false, email: email}) when is_binary(email), do: true
  def can_author?(_), do: false

  defp normalize_email(email), do: email |> to_string() |> String.trim() |> String.downcase()

  defp allowed_emails do
    Application.get_env(:uitstalling, :allowed_emails, [])
    |> Enum.map(&String.downcase/1)
  end
end
