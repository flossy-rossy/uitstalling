defmodule Uitstalling.Accounts.WebAuthn do
  @moduledoc """
  Two-legged on both sides (begin → complete). `begin` returns a
  `%Wax.Challenge{}` (stash in the session) plus a JSON-ready options map for
  the browser. Login is usernameless/discoverable: no allowCredentials, and
  complete resolves the credential by its id.
  """
  import Ecto.Query

  alias Uitstalling.Accounts.{User, WebauthnCredential}
  alias Uitstalling.Repo

  # COSE algorithms we accept, by preference: EdDSA, ES256, RS256 (Windows Hello).
  @pub_key_cred_params [
    %{type: "public-key", alg: -8},
    %{type: "public-key", alg: -7},
    %{type: "public-key", alg: -257}
  ]

  # Ceremony budget the browser enforces. Cross-device (QR + phone) sign-in
  # takes minutes, not seconds — find phone, unlock, scan, BLE handshake,
  # biometric — and 60s was aborting it mid-flow. 5 minutes follows passkey
  # UX guidance for hybrid flows.
  @timeout_ms 300_000

  # Server-side challenge validity for Wax verification, in seconds. Wax's
  # own default is 120s, which expires DURING a QR flow the browser happily
  # allows — keep it comfortably above @timeout_ms so the browser is always
  # the binding constraint.
  @challenge_ttl_s 600

  # ----- Registration -----------------------------------------------------

  @doc "Builds a registration challenge for `user` and the matching browser options."
  def new_registration_challenge(%User{} = user) do
    challenge =
      Wax.new_registration_challenge(
        origin: origin(),
        rp_id: rp_id(),
        user_verification: "required",
        timeout: @challenge_ttl_s
      )

    options = %{
      challenge: b64(challenge.bytes),
      rp: %{name: rp_name(), id: rp_id()},
      user: %{
        id: b64(user_handle(user)),
        name: user.email || "user",
        displayName: user.name || user.email || "user"
      },
      pubKeyCredParams: @pub_key_cred_params,
      authenticatorSelection: %{residentKey: "required", userVerification: "required"},
      attestation: "none",
      timeout: @timeout_ms
    }

    {challenge, options}
  end

  @doc "Verifies a registration response and stores the credential for `user`."
  def verify_registration(%User{} = user, params, %Wax.Challenge{} = challenge, opts \\ []) do
    with {:ok, attestation_object} <- decode(params["response"]["attestationObject"]),
         {:ok, client_data_json} <- decode(params["response"]["clientDataJSON"]),
         {:ok, {auth_data, _attestation_result}} <-
           Wax.register(attestation_object, client_data_json, challenge) do
      acd = auth_data.attested_credential_data

      %WebauthnCredential{}
      |> WebauthnCredential.changeset(%{
        user_id: user.id,
        # From the verified authenticator data, not the client-supplied rawId.
        credential_id: acd.credential_id,
        public_key: acd.credential_public_key,
        sign_count: auth_data.sign_count,
        rp_id: rp_id(),
        label: Keyword.get(opts, :label)
      })
      |> Repo.insert()
    end
  end

  # ----- Authentication ---------------------------------------------------

  @doc "Builds a usernameless authentication challenge and browser options."
  def new_authentication_challenge do
    challenge =
      Wax.new_authentication_challenge(
        origin: origin(),
        rp_id: rp_id(),
        user_verification: "required",
        timeout: @challenge_ttl_s
      )

    options = %{
      challenge: b64(challenge.bytes),
      rpId: rp_id(),
      allowCredentials: [],
      userVerification: "required",
      timeout: @timeout_ms
    }

    {challenge, options}
  end

  @doc "Verifies an assertion and returns the owning user."
  def verify_authentication(params, %Wax.Challenge{} = challenge) do
    with {:ok, credential_id} <- decode(params["rawId"]),
         {:ok, auth_data_bin} <- decode(params["response"]["authenticatorData"]),
         {:ok, sig} <- decode(params["response"]["signature"]),
         {:ok, client_data_json} <- decode(params["response"]["clientDataJSON"]),
         %WebauthnCredential{} = cred <- get_credential(credential_id),
         {:ok, auth_data} <-
           Wax.authenticate(
             credential_id,
             auth_data_bin,
             sig,
             client_data_json,
             challenge,
             [{credential_id, cred.public_key}]
           ),
         {:ok, _cred} <- update_after_auth(cred, auth_data.sign_count) do
      {:ok, Repo.get!(User, cred.user_id)}
    else
      nil -> {:error, :credential_not_found}
      {:error, _} = error -> error
    end
  end

  # ----- Internals --------------------------------------------------------

  defp get_credential(credential_id) do
    Repo.one(from c in WebauthnCredential, where: c.credential_id == ^credential_id)
  end

  # wax_ verifies the signature but leaves the signCount comparison to the
  # caller. Synced passkeys often report 0 — exempt the both-zero case;
  # otherwise the count must strictly increase, else reject as a possible clone.
  defp update_after_auth(%WebauthnCredential{sign_count: stored} = cred, new_count) do
    cond do
      new_count == 0 and stored == 0 -> touch(cred, %{last_used_at: now()})
      new_count > stored -> touch(cred, %{sign_count: new_count, last_used_at: now()})
      true -> {:error, :sign_count_regression}
    end
  end

  defp touch(cred, attrs), do: cred |> Ecto.Changeset.change(attrs) |> Repo.update()

  defp decode(nil), do: {:error, :missing_field}
  defp decode(str) when is_binary(str), do: Base.url_decode64(str, padding: false)
  defp decode(_), do: {:error, :invalid_field}

  # Opaque, stable per user; login resolves by credential id so this is never
  # read back. 16 bytes from the uuid.
  defp user_handle(%User{id: id}), do: Ecto.UUID.dump!(id)

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp config, do: Application.fetch_env!(:uitstalling, :webauthn)
  defp rp_id, do: Keyword.fetch!(config(), :rp_id)
  defp origin, do: Keyword.fetch!(config(), :origin)
  defp rp_name, do: Keyword.fetch!(config(), :rp_name)
end
