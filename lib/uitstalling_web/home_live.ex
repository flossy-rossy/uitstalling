defmodule UitstallingWeb.HomeLive do
  @moduledoc """
  The front door: two halves, two moods. WRITING (the warm private page) or
  PRESENTATION (the dark stage). Each half is one link — /write or /decks —
  and the page itself holds no state worth keeping.
  """

  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    author? = Accounts.can_author?(user)

    greet_name =
      if author? and is_binary(user.name) and user.name != "" do
        user.name |> String.split(" ", trim: true) |> List.first()
      end

    {:ok, assign(socket, page_title: "UIT", author?: author?, greet_name: greet_name)}
  end

  def render(assigns) do
    ~H"""
    <main class="min-h-dvh flex flex-col">
      <header class="px-8 py-5 bg-zinc-950 flex items-center justify-between gap-4 flex-wrap">
        <p class="font-mono text-amber-400 text-sm tracking-widest uppercase">UIT · uitstalling</p>
        <p class="font-mono text-xs text-zinc-400">
          <%= if @greet_name do %>
            {@greet_name} — what are we making today?
          <% else %>
            What are we making today?
          <% end %>
        </p>
        <.link
          :if={@author?}
          href={~p"/auth/logout"}
          method="delete"
          class="font-mono text-xs text-zinc-500 hover:text-amber-400"
        >
          sign out
        </.link>
        <.link
          :if={not @author?}
          navigate={~p"/auth/login"}
          class="font-mono text-xs text-zinc-500 hover:text-amber-400"
        >
          closed beta — sign in
        </.link>
      </header>

      <div class="flex-1 flex flex-col md:flex-row">
        <.link
          navigate={~p"/write"}
          class="group flex-1 md:hover:flex-[1.25] transition-all duration-300 bg-[#f8f3e7] text-stone-900 font-literata flex flex-col items-center justify-center gap-4 px-8 py-20"
        >
          <p class="font-mono text-xs tracking-widest uppercase text-amber-800">writing</p>
          <h2 class="text-5xl sm:text-6xl font-bold group-hover:underline decoration-2 underline-offset-8">
            Write
          </h2>
          <p class="text-stone-500 text-lg italic text-center">
            novels, worlds, plans — private, encrypted
          </p>
        </.link>

        <.link
          navigate={~p"/decks"}
          class="group flex-1 md:hover:flex-[1.25] transition-all duration-300 bg-zinc-950 text-zinc-100 flex flex-col items-center justify-center gap-4 px-8 py-20"
        >
          <p class="font-mono text-xs tracking-widest uppercase text-amber-400">presentations</p>
          <h2 class="text-5xl sm:text-6xl font-bold group-hover:text-amber-400 transition">
            Present
          </h2>
          <p class="text-zinc-500 text-lg text-center">
            describe your talk, get your deck
          </p>
        </.link>
      </div>
    </main>
    """
  end
end
