defmodule Uitstalling.Accounts do
  @moduledoc """
  Users + the closed-beta authorship gate.

  During the closed beta, only allowlisted emails (`:allowed_emails` config)
  and invited emails may register a passkey and author decks. An empty
  allowlist means open (the future public mode). Either way, each passkey
  registration consumes a single-use invite when one exists, and an account
  that already has a passkey can only add another via a fresh invite.
  Presenting is always public — no user needed.
  """

  import Ecto.Query

  alias Uitstalling.Accounts.{Contact, Invite, User, UserSettings, WebauthnCredential}
  alias Uitstalling.Repo
  alias Uitstalling.Slug

  def get_user(nil), do: nil
  def get_user(id), do: Repo.get(User, id)

  # ----- Contacts ----------------------------------------------------------------
  #
  # Directed user→user connections (the seam future sharing builds on). Adding
  # is idempotent; you look someone up by the email they registered with.

  @doc """
  Add the user with `email` to `user`'s contacts. `{:ok, contact_user}`,
  `{:error, :not_found}` if no such account, or `{:error, :self}`.
  """
  def add_contact(%User{} = user, email) do
    case get_user_by_email(normalize_email(email)) do
      nil ->
        {:error, :not_found}

      %User{id: id} when id == user.id ->
        {:error, :self}

      %User{} = other ->
        Repo.insert!(
          %Contact{
            user_id: user.id,
            contact_id: other.id,
            inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          on_conflict: :nothing,
          conflict_target: [:user_id, :contact_id]
        )

        {:ok, other}
    end
  end

  @doc "A user's contacts as `%{id, name, email}`, by name."
  def list_contacts(%User{} = user) do
    Repo.all(
      from(c in Contact,
        where: c.user_id == ^user.id,
        join: u in User,
        on: u.id == c.contact_id,
        order_by: [asc: u.name, asc: u.email],
        select: %{id: u.id, name: u.name, email: u.email}
      )
    )
  end

  @doc "Remove a contact from `user`'s list."
  def remove_contact(%User{} = user, contact_id) do
    Repo.delete_all(
      from(c in Contact, where: c.user_id == ^user.id and c.contact_id == ^contact_id)
    )

    :ok
  end

  @doc "A user's settings, defaulting when never saved."
  def settings(%User{settings: %UserSettings{} = s}), do: s
  def settings(%User{}), do: %UserSettings{}

  @doc """
  Update a user's settings from `attrs` (a map with `enabled_element_types`
  and/or `custom_element_types`). Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def update_settings(%User{} = user, attrs) do
    user
    |> Ecto.Changeset.cast(%{"settings" => attrs}, [])
    |> Ecto.Changeset.cast_embed(:settings, with: &UserSettings.changeset/2)
    |> Repo.update()
  end

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

  Inviting mints a single-use `Invite` (see `Uitstalling.Accounts.Invite`)
  that registering a passkey will claim, regardless of the AUTHOR_EMAILS
  allowlist. Re-inviting someone who lost their passkey is the recovery flow:
  it mints a fresh invite so they can register a new one.
  """
  def invite_user(email, name) when is_binary(name) do
    email = normalize_email(email)

    user =
      case get_user_by_email(email) do
        nil ->
          Repo.insert!(%User{email: email, name: name, anonymous: false})

        user ->
          user |> Ecto.Changeset.change(name: name, anonymous: false) |> Repo.update!()
      end
      |> ensure_slug!()

    unless unclaimed_invite(email) do
      Repo.insert!(%Invite{email: email, name: name})
    end

    user
  end

  @doc """
  Find or create the user a passkey registration ceremony is for. Does not
  consume anything — `claim_invites/1` runs after the passkey is verified.

    * an account that already has a passkey needs a live invite to add
      another (`{:error, :invite_required}` otherwise — recovery is a
      re-invite, not open season on any known email)
    * a passkey-less account (a pending invite, or an abandoned first
      ceremony) may proceed with an invite or via the allowlist
    * a brand-new email needs an invite or the allowlist (empty list = open)
  """
  def register_user(email, name \\ nil) do
    email = normalize_email(email)
    user = get_user_by_email(email)
    invite = unclaimed_invite(email)

    cond do
      user && may_register_credential?(user) ->
        {:ok, ensure_slug!(user)}

      user ->
        {:error, :invite_required}

      invite || allowed_email?(email) ->
        name = name || (invite && invite.name)
        {:ok, ensure_slug!(Repo.insert!(%User{email: email, name: name, anonymous: false}))}

      true ->
        {:error, :not_allowed}
    end
  end

  @doc """
  Whether `user` may register a (new) passkey right now: a live invite always
  authorizes it; without one only a first passkey is allowed, and only via
  the allowlist. Re-checked when the ceremony completes, so an invite claimed
  mid-ceremony (or a passkey added from another tab) closes the door.
  """
  def may_register_credential?(%User{} = user) do
    cond do
      unclaimed_invite(user.email) -> true
      has_credentials?(user) -> false
      true -> allowed_email?(user.email)
    end
  end

  @doc """
  Claim the live invite for `user`'s email after a passkey was successfully
  registered. A no-op when registration was authorized by the allowlist.
  """
  def claim_invites(%User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(i in Invite, where: i.email == ^user.email and is_nil(i.claimed_at))
    |> Repo.update_all(set: [claimed_at: now, claimed_by_id: user.id, updated_at: now])
  end

  @doc "Whether the user has at least one registered passkey."
  def has_credentials?(%User{id: id}) do
    Repo.exists?(from c in WebauthnCredential, where: c.user_id == ^id)
  end

  @doc "The live (unclaimed) invite for an email, or nil."
  def unclaimed_invite(email) when is_binary(email) do
    Repo.one(
      from i in Invite,
        where: i.email == ^normalize_email(email) and is_nil(i.claimed_at)
    )
  end

  def unclaimed_invite(_), do: nil

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
