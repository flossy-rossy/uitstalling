defmodule UitstallingWeb.WritingSettingsLive do
  @moduledoc """
  Per-user writing settings — today, which plan-element tag types you use:
  a small always-on core, a curated gallery you toggle on, and up to five
  custom types you name and colour yourself. The home for future per-user
  writing preferences too. Owner-only, like everything under /write.
  """

  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
  alias Uitstalling.Writing
  alias UitstallingWeb.WritingComponents

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    cond do
      is_nil(user) ->
        {:ok,
         socket
         |> put_flash(:error, "Sign in to write")
         |> redirect(to: ~p"/auth/login?return_to=/write/settings")}

      not Accounts.can_author?(user) ->
        {:ok,
         socket |> put_flash(:error, "Writing is for registered accounts") |> redirect(to: ~p"/")}

      true ->
        {:ok,
         socket
         |> assign(
           page_title: "Writing settings",
           new_label: "",
           new_color: "amber",
           error: nil,
           contact_error: nil,
           contacts: Accounts.list_contacts(user)
         )
         |> load_settings()}
    end
  end

  defp load_settings(socket) do
    settings = Accounts.settings(socket.assigns.current_user)

    assign(socket,
      enabled: settings.enabled_element_types,
      customs: settings.custom_element_types,
      bullet_style: settings.bullet_style
    )
  end

  def handle_event("add_contact", %{"email" => email}, socket) do
    case Accounts.add_contact(socket.assigns.current_user, email) do
      {:ok, _contact} ->
        {:noreply,
         assign(socket,
           contact_error: nil,
           contacts: Accounts.list_contacts(socket.assigns.current_user)
         )}

      {:error, :self} ->
        {:noreply, assign(socket, contact_error: "That's you.")}

      {:error, :not_found} ->
        {:noreply,
         assign(socket,
           contact_error: "No account uses that email yet — they need to sign up first."
         )}
    end
  end

  def handle_event("remove_contact", %{"id" => id}, socket) do
    :ok = Accounts.remove_contact(socket.assigns.current_user, id)
    {:noreply, assign(socket, contacts: Accounts.list_contacts(socket.assigns.current_user))}
  end

  def handle_event("toggle_curated", %{"type" => type}, socket) do
    enabled =
      if type in socket.assigns.enabled,
        do: socket.assigns.enabled -- [type],
        else: [type | socket.assigns.enabled]

    {:noreply, save(socket, enabled, socket.assigns.customs)}
  end

  def handle_event("pick_color", %{"color" => color}, socket) do
    if color in Writing.color_slots() do
      {:noreply, assign(socket, new_color: color)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_custom", %{"label" => label}, socket) do
    added = socket.assigns.customs ++ [%{"label" => label, "color" => socket.assigns.new_color}]

    case save(socket, socket.assigns.enabled, added) do
      %{assigns: %{error: nil}} = socket -> {:noreply, assign(socket, new_label: "")}
      socket -> {:noreply, socket}
    end
  end

  def handle_event("remove_custom", %{"key" => key}, socket) do
    kept = Enum.reject(socket.assigns.customs, &(&1.key == key))
    {:noreply, save(socket, socket.assigns.enabled, kept)}
  end

  def handle_event("pick_bullet", %{"style" => style}, socket) do
    {:noreply, save(socket, socket.assigns.enabled, socket.assigns.customs, style)}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # Persist enabled + customs together (custom keys are re-derived from labels
  # by the embedded changeset), refresh the current user, re-read.
  defp save(socket, enabled, customs, bullet_style \\ nil) do
    params = %{
      "enabled_element_types" => enabled,
      "custom_element_types" => Enum.map(customs, &custom_params/1),
      "bullet_style" => bullet_style || socket.assigns.bullet_style
    }

    case Accounts.update_settings(socket.assigns.current_user, params) do
      {:ok, user} ->
        socket |> assign(current_user: user, error: nil) |> load_settings()

      {:error, changeset} ->
        assign(socket, error: settings_error(changeset))
    end
  end

  defp custom_params(%{label: label, color: color}), do: %{"label" => label, "color" => color}
  defp custom_params(%{"label" => _, "color" => _} = params), do: params

  defp settings_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> collect_messages()
    |> List.first() || "Couldn't save that."
  end

  defp collect_messages(errors) when is_map(errors),
    do: Enum.flat_map(errors, fn {_k, v} -> collect_messages(v) end)

  defp collect_messages(errors) when is_list(errors),
    do: Enum.flat_map(errors, &collect_messages/1)

  defp collect_messages(msg) when is_binary(msg), do: [msg]
  defp collect_messages(_), do: []

  def render(assigns) do
    assigns =
      assigns
      |> assign(:palette, WritingComponents.page_theme("paper"))
      |> assign(:catalog, Writing.element_type_catalog())
      |> assign(:at_cap, length(assigns.customs) >= Writing.max_custom_types())

    ~H"""
    <main class={["min-h-dvh px-8 sm:px-16 py-16 font-literata", @palette.bg, @palette.ink]}>
      <div class="max-w-2xl mx-auto">
        <.link navigate={~p"/write"} class={["font-mono text-xs", @palette.muted, "hover:underline"]}>
          ← your shelf
        </.link>
        <h1 class="mt-6 text-4xl font-bold">Your tags</h1>
        <p class={["mt-3 text-lg", @palette.muted]}>
          The kinds of thing you track — characters, places, and whatever else your
          story needs. Core tags are always on; turn on more, or make your own.
        </p>

        <p :if={@error} class="mt-4 text-sm text-red-700">{@error}</p>

        <section class="mt-10">
          <p class={["font-mono text-xs tracking-wider", @palette.muted]}>ALWAYS ON</p>
          <div class="mt-3 flex flex-wrap gap-2">
            <span
              :for={type <- Writing.core_element_types()}
              class={[
                "inline-flex items-center gap-1.5 rounded-full ring-1 px-3 py-1 text-sm font-semibold",
                WritingComponents.chip_class(@catalog[type].color, @palette.light)
              ]}
            >
              {@catalog[type].label}
            </span>
          </div>
        </section>

        <section class="mt-10">
          <p class={["font-mono text-xs tracking-wider", @palette.muted]}>GALLERY — TAP TO TOGGLE</p>
          <div class="mt-3 flex flex-wrap gap-2">
            <button
              :for={type <- Writing.curated_element_types()}
              phx-click="toggle_curated"
              phx-value-type={type}
              class={[
                "inline-flex items-center gap-1.5 rounded-full ring-1 px-3 py-1 text-sm font-semibold transition",
                WritingComponents.chip_class(@catalog[type].color, @palette.light),
                if(type in @enabled, do: "opacity-100", else: "opacity-40 hover:opacity-70")
              ]}
            >
              <span :if={type in @enabled}>✓</span> {@catalog[type].label}
            </button>
          </div>
        </section>

        <section class="mt-10">
          <p class={["font-mono text-xs tracking-wider", @palette.muted]}>
            YOUR OWN — {length(@customs)}/{Writing.max_custom_types()}
          </p>

          <div :if={@customs != []} class="mt-3 flex flex-wrap gap-2">
            <span
              :for={custom <- @customs}
              class={[
                "group/c inline-flex items-center gap-1.5 rounded-full ring-1 px-3 py-1 text-sm font-semibold",
                WritingComponents.chip_class(custom.color, @palette.light)
              ]}
            >
              {custom.label}
              <button
                phx-click="remove_custom"
                phx-value-key={custom.key}
                class="opacity-0 group-hover/c:opacity-60 hover:!opacity-100"
                title="Remove"
              >
                ✕
              </button>
            </span>
          </div>

          <form
            :if={not @at_cap}
            phx-submit="add_custom"
            phx-change="noop"
            class="mt-4 flex items-center gap-3 flex-wrap"
          >
            <div class="flex items-center gap-1.5">
              <button
                :for={color <- Writing.color_slots()}
                type="button"
                phx-click="pick_color"
                phx-value-color={color}
                title={color}
                class={[
                  "w-5 h-5 rounded-full ring-2 transition",
                  if(color == @new_color, do: "scale-110", else: "opacity-50 hover:opacity-100")
                ]}
                style={"background: #{WritingComponents.color_hex(color)}; --tw-ring-color: #{WritingComponents.color_hex(color)}66"}
              ></button>
            </div>
            <input
              type="text"
              name="label"
              value={@new_label}
              required
              maxlength="32"
              placeholder="A new kind of thing…"
              autocomplete="off"
              class={[
                "flex-1 min-w-48 rounded-lg px-4 py-2 bg-transparent border",
                @palette.rule,
                "placeholder:opacity-50 focus:outline-none"
              ]}
            />
            <button
              type="submit"
              class="px-5 py-2 rounded-lg bg-stone-900 text-stone-50 font-semibold hover:bg-stone-700 transition"
            >
              + Add
            </button>
          </form>
          <p :if={@at_cap} class={["mt-4 text-sm", @palette.muted]}>
            You've used all {Writing.max_custom_types()} custom tags — remove one to add another.
          </p>
        </section>

        <section class={["mt-14 pt-8 border-t", @palette.rule]}>
          <p class={["font-mono text-xs tracking-wider", @palette.muted]}>READING</p>
          <p class={["mt-2 text-sm", @palette.muted]}>
            How bullet lists look in read view. In the editor they're always typed as <code>-</code>.
          </p>
          <div class="mt-3 flex flex-wrap gap-2">
            <button
              :for={
                {style, glyph} <- [{"disc", "•"}, {"dash", "–"}, {"circle", "◦"}, {"square", "▪"}]
              }
              phx-click="pick_bullet"
              phx-value-style={style}
              class={[
                "inline-flex items-center gap-2 rounded-full ring-1 px-3 py-1 text-sm font-semibold transition",
                @palette.rule,
                if(style == @bullet_style, do: "opacity-100", else: "opacity-40 hover:opacity-70")
              ]}
            >
              <span class="text-base leading-none">{glyph}</span> {style}
            </button>
          </div>
        </section>

        <section class={["mt-14 pt-8 border-t", @palette.rule]}>
          <p class={["font-mono text-xs tracking-wider", @palette.muted]}>CONTACTS</p>
          <p class={["mt-2 text-sm", @palette.muted]}>
            People you write with. Adding someone here is the first step toward
            sharing work with them.
          </p>

          <div :if={@contacts != []} class="mt-4 grid gap-2">
            <div
              :for={contact <- @contacts}
              class={[
                "group flex items-center justify-between gap-4 rounded-lg border px-4 py-2.5",
                @palette.rule
              ]}
            >
              <span>
                <span class="font-semibold">{contact.name || contact.email}</span>
                <span :if={contact.name} class={["ml-2 text-sm", @palette.muted]}>{contact.email}</span>
              </span>
              <button
                phx-click="remove_contact"
                phx-value-id={contact.id}
                class={[
                  "opacity-0 group-hover:opacity-100 font-mono text-xs",
                  @palette.faint,
                  "hover:text-red-600"
                ]}
              >
                remove
              </button>
            </div>
          </div>

          <form phx-submit="add_contact" class="mt-4 flex gap-3">
            <input
              type="email"
              name="email"
              required
              placeholder="Their email address…"
              autocomplete="off"
              class={[
                "flex-1 rounded-lg px-4 py-2 bg-transparent border",
                @palette.rule,
                "placeholder:opacity-50 focus:outline-none"
              ]}
            />
            <button
              type="submit"
              class="px-5 py-2 rounded-lg bg-stone-900 text-stone-50 font-semibold hover:bg-stone-700 transition"
            >
              + Add contact
            </button>
          </form>
          <p :if={@contact_error} class="mt-2 text-sm text-red-700">{@contact_error}</p>
        </section>
      </div>
    </main>
    """
  end
end
