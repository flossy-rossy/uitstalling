// WebAuthn / passkey ceremonies for the site surface.
//
// Talks to the controller begin/complete JSON endpoints over fetch(). Uses the
// modern browser JSON API (parseCreationOptionsFromJSON / parseRequestOptionsFromJSON
// / cred.toJSON()) when present, falling back to manual base64url conversion on
// older WebAuthn browsers (kept for device diversity).
//
// Buttons opt in via data attributes on [data-webauthn] elements, handled by a
// single document-level delegated listener — everything is read from data-* at
// click time, so it survives LiveView navigation and DOM patching.
//
// The login page may also carry a [data-webauthn-conditional] marker: on load we
// park a conditional-mediation get() so stored passkeys surface in the autofill
// of the username field (gesture-free, non-modal, degrades to nothing when the
// device has no passkeys). Only one WebAuthn request may be pending per page, so
// the parked request is aborted before any modal button ceremony runs.

// --- base64url helpers (fallback path only) --------------------------------

const b64urlToBuf = (s) => {
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/"))
  return Uint8Array.from(bin, (c) => c.charCodeAt(0)).buffer
}

const bufToB64url = (buf) => {
  let bin = ""
  const u8 = new Uint8Array(buf)
  for (let i = 0; i < u8.byteLength; i++) bin += String.fromCharCode(u8[i])
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "")
}

// --- transport -------------------------------------------------------------

async function postJSON(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      "x-csrf-token": document.querySelector("meta[name='csrf-token']")?.content
    },
    body: JSON.stringify(body || {})
  })

  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`)
  return data
}

// --- option / credential marshalling (native API, manual fallback) ---------

function toCreationOptions(json) {
  if (PublicKeyCredential.parseCreationOptionsFromJSON) {
    return PublicKeyCredential.parseCreationOptionsFromJSON(json)
  }

  return {
    ...json,
    challenge: b64urlToBuf(json.challenge),
    user: {...json.user, id: b64urlToBuf(json.user.id)},
    excludeCredentials: (json.excludeCredentials || []).map((c) => ({...c, id: b64urlToBuf(c.id)}))
  }
}

function toRequestOptions(json) {
  if (PublicKeyCredential.parseRequestOptionsFromJSON) {
    return PublicKeyCredential.parseRequestOptionsFromJSON(json)
  }

  return {
    ...json,
    challenge: b64urlToBuf(json.challenge),
    allowCredentials: (json.allowCredentials || []).map((c) => ({...c, id: b64urlToBuf(c.id)}))
  }
}

function credToJSON(cred) {
  if (cred.toJSON) return cred.toJSON()

  const r = cred.response
  const out = {
    id: cred.id,
    rawId: bufToB64url(cred.rawId),
    type: cred.type,
    response: {clientDataJSON: bufToB64url(r.clientDataJSON)}
  }

  if (r.attestationObject) {
    out.response.attestationObject = bufToB64url(r.attestationObject)
  } else {
    out.response.authenticatorData = bufToB64url(r.authenticatorData)
    out.response.signature = bufToB64url(r.signature)
    out.response.userHandle = r.userHandle ? bufToB64url(r.userHandle) : null
  }

  return out
}

// --- ceremonies ------------------------------------------------------------

async function registerPasskey({beginUrl, completeUrl, token, label, displayName, email}) {
  const {publicKey} = await postJSON(beginUrl, {token, label, display_name: displayName, name: displayName, email})
  const cred = await navigator.credentials.create({publicKey: toCreationOptions(publicKey)})
  return postJSON(completeUrl, {credential: credToJSON(cred), label})
}

async function authenticatePasskey({beginUrl, completeUrl}) {
  const {publicKey} = await postJSON(beginUrl, {})
  const cred = await navigator.credentials.get({publicKey: toRequestOptions(publicKey)})
  return postJSON(completeUrl, {credential: credToJSON(cred)})
}

// --- conditional mediation (login autofill) ---------------------------------

let conditionalAbort = null

function abortConditional() {
  if (conditionalAbort) {
    conditionalAbort.abort()
    conditionalAbort = null
  }
}

async function parkConditionalLogin(el) {
  if (!window.PublicKeyCredential?.isConditionalMediationAvailable) return
  if (!(await PublicKeyCredential.isConditionalMediationAvailable())) return

  abortConditional()
  conditionalAbort = new AbortController()

  try {
    const {publicKey} = await postJSON(el.dataset.beginUrl, {})

    const cred = await navigator.credentials.get({
      publicKey: toRequestOptions(publicKey),
      mediation: "conditional",
      signal: conditionalAbort.signal
    })

    const result = await postJSON(el.dataset.completeUrl, {credential: credToJSON(cred)})
    if (result.redirect) window.location.assign(result.redirect)
  } catch (err) {
    // AbortError = we made way for a modal ceremony; anything else is logged
    // quietly — the button flow remains as the visible path.
    if (err.name !== "AbortError") console.debug("Conditional WebAuthn ended:", err)
  } finally {
    conditionalAbort = null
  }
}

// --- declarative wiring ------------------------------------------------------

async function runCeremony(el) {
  const statusEl = el.dataset.statusTarget && document.getElementById(el.dataset.statusTarget)
  const setStatus = (msg, kind) => {
    if (!statusEl) return
    statusEl.textContent = msg
    statusEl.dataset.kind = kind || ""
  }

  if (!window.PublicKeyCredential) {
    setStatus("This browser doesn't support passkeys, or you're not on a secure origin.", "error")
    return
  }

  // Only one WebAuthn request may be pending — release the parked login.
  abortConditional()

  const labelInput = el.dataset.labelInput && document.getElementById(el.dataset.labelInput)
  const nameInput = el.dataset.nameInput && document.getElementById(el.dataset.nameInput)

  el.disabled = true
  setStatus("Waiting for your authenticator…", "pending")

  try {
    const emailInput = el.dataset.emailInput && document.getElementById(el.dataset.emailInput)
    const opts = {
      beginUrl: el.dataset.beginUrl,
      completeUrl: el.dataset.completeUrl,
      token: el.dataset.token,
      label: labelInput ? labelInput.value : undefined,
      displayName: nameInput ? nameInput.value : undefined,
      email: emailInput ? emailInput.value : undefined
    }

    const result =
      el.dataset.webauthn === "register"
        ? await registerPasskey(opts)
        : await authenticatePasskey(opts)

    setStatus("Success — redirecting…", "ok")
    if (result.redirect) window.location.assign(result.redirect)
  } catch (err) {
    console.error("WebAuthn ceremony failed:", err)
    // NotAllowedError = user dismissed/timed out the OS prompt.
    const msg = err.name === "NotAllowedError" ? "Cancelled or timed out." : err.message
    setStatus(msg || "Something went wrong.", "error")
    el.disabled = false
  }
}

document.addEventListener("click", (event) => {
  const el = event.target.closest("[data-webauthn]")
  if (!el || el.disabled) return
  event.preventDefault()
  runCeremony(el)
})

function initConditional() {
  const marker = document.querySelector("[data-webauthn-conditional]")
  if (marker) parkConditionalLogin(marker)
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initConditional)
} else {
  initConditional()
}
