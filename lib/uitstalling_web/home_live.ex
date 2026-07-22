defmodule UitstallingWeb.HomeLive do
  @moduledoc "Landing page: brand, deck list, and the New presentation button."

  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
  alias Uitstalling.Decks

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    author? = Accounts.can_author?(user)
    decks = if author?, do: Decks.list(user.id), else: []

    # First splash for a fresh invitee: greet them by the name set at invite
    # time. Once they have decks, the standard headline returns.
    greet_name =
      if author? and decks == [] and is_binary(user.name) and user.name != "" do
        user.name |> String.split(" ", trim: true) |> List.first()
      end

    public_slug = if author?, do: Accounts.ensure_slug!(user).slug

    {:ok,
     assign(socket,
       page_title: "UIT",
       author?: author?,
       decks: decks,
       greet_name: greet_name,
       public_slug: public_slug
     )}
  end

  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-zinc-950 text-zinc-100 px-8 sm:px-16 py-16">
      <div class="max-w-5xl mx-auto">
        <header class="flex items-end justify-between flex-wrap gap-6">
          <div>
            <p class="font-mono text-amber-400 text-sm tracking-widest uppercase">
              UIT · uitstalling
            </p>
            <h1 class="mt-4 text-5xl sm:text-6xl font-bold leading-tight">
              <%= if @greet_name do %>
                Welcome <span class="text-amber-400">{@greet_name}</span>,<br />
                let's get you presenting.
              <% else %>
                Describe your talk.<br />
                <span class="text-amber-400">Get your deck.</span>
              <% end %>
            </h1>
          </div>
          <.link
            :if={@author?}
            navigate={~p"/new"}
            class="px-8 py-4 rounded-lg bg-amber-500 hover:bg-amber-400 text-zinc-950 font-bold text-lg shadow-lg shadow-amber-500/20 transition"
          >
            + New presentation
          </.link>
          <.link
            :if={not @author?}
            navigate={~p"/auth/login"}
            class="px-8 py-4 rounded-lg bg-amber-500 hover:bg-amber-400 text-zinc-950 font-bold text-lg transition"
          >
            Sign in
          </.link>
        </header>

        <section :if={not @author?} class="mt-16 max-w-xl">
          <p class="text-zinc-400 text-lg leading-relaxed">
            UIT is in closed beta. Sign in with your passkey to build presentations —
            or open a presentation link someone shared to view it.
          </p>
        </section>

        <section :if={@author?} class="mt-16">
          <div class="flex items-center justify-between mb-4">
            <p class="font-mono text-zinc-500 text-xs tracking-wider">
              YOUR PRESENTATIONS
              <.link
                :if={@public_slug}
                navigate={"/#{@public_slug}"}
                class="ml-3 text-zinc-600 hover:text-amber-400 normal-case tracking-normal"
              >
                → your public page: /{@public_slug}
              </.link>
              <.link
                navigate={~p"/write"}
                class="ml-3 text-zinc-600 hover:text-amber-400 normal-case tracking-normal"
              >
                → your writing (private)
              </.link>
            </p>
            <.link
              href={~p"/auth/logout"}
              method="delete"
              class="font-mono text-xs text-zinc-500 hover:text-amber-400"
            >
              sign out
            </.link>
          </div>

          <p :if={@decks == []} class="text-zinc-500 text-lg">
            Nothing here yet — make your first one.
          </p>

          <div class="grid sm:grid-cols-2 gap-4">
            <div
              :for={{id, deck} <- @decks}
              class="group rounded-xl ring-1 ring-zinc-800 hover:ring-amber-500/60 bg-zinc-900/60 p-6 transition"
            >
              <div class="flex items-start justify-between gap-4">
                <.link navigate={~p"/deck/#{id}"} class="flex-1">
                  <p class="text-xl font-semibold leading-snug group-hover:text-amber-400 transition">
                    {deck.title}
                  </p>
                  <p class="mt-2 font-mono text-xs text-zinc-500">
                    {length(deck.slides)} slides · {deck.theme}
                    <span :if={deck.voice}> · {String.slice(deck.voice, 0, 40)}</span>
                  </p>
                </.link>
                <span class={[
                  "mt-1 inline-block w-3 h-3 rounded-full shrink-0",
                  if(deck.theme == "midnight", do: "bg-cyan-400", else: "bg-amber-400")
                ]}></span>
              </div>
              <div class="mt-4 flex gap-4 font-mono text-xs">
                <.link navigate={~p"/deck/#{id}"} class="text-amber-400 hover:text-amber-300">
                  present →
                </.link>
                <.link navigate={~p"/deck/#{id}/remote"} class="text-zinc-500 hover:text-zinc-300">
                  remote
                </.link>
              </div>
            </div>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
