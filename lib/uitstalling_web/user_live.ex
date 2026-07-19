defmodule UitstallingWeb.UserLive do
  @moduledoc """
  A presenter's public page: /:user_slug lists all their presentations —
  no login, no edit affordances, just links to present (and each deck's
  remote). Decks are public-by-link already; this is the shelf they sit on.
  """

  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
  alias Uitstalling.Decks

  def mount(%{"user_slug" => user_slug}, _session, socket) do
    case Accounts.get_user_by_slug(user_slug) do
      nil ->
        {:ok, socket |> put_flash(:error, "No such presenter") |> redirect(to: ~p"/")}

      owner ->
        # Old decks mint their title slug on first public view.
        entries =
          for {id, deck} <- Decks.list(owner.id) do
            %{deck: deck, path: "/#{user_slug}/#{Decks.ensure_deck_slug(id)}"}
          end

        {:ok,
         assign(socket,
           page_title: owner.name || user_slug,
           owner_name: owner.name || user_slug,
           user_slug: user_slug,
           entries: entries
         )}
    end
  end

  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-zinc-950 text-zinc-100 px-8 sm:px-16 py-16">
      <div class="max-w-5xl mx-auto">
        <header>
          <p class="font-mono text-amber-400 text-sm tracking-widest uppercase">
            <span class="text-amber-400">8</span>stal · presentations
          </p>
          <h1 class="mt-4 text-5xl sm:text-6xl font-bold leading-tight">
            {@owner_name}<span class="text-amber-400">.</span>
          </h1>
        </header>

        <section class="mt-16">
          <p :if={@entries == []} class="text-zinc-500 text-lg">
            Nothing published here yet.
          </p>

          <div class="grid sm:grid-cols-2 gap-4">
            <div
              :for={entry <- @entries}
              class="group rounded-xl ring-1 ring-zinc-800 hover:ring-amber-500/60 bg-zinc-900/60 p-6 transition"
            >
              <div class="flex items-start justify-between gap-4">
                <.link navigate={entry.path} class="flex-1">
                  <p class="text-xl font-semibold leading-snug group-hover:text-amber-400 transition">
                    {entry.deck.title}
                  </p>
                  <p class="mt-2 font-mono text-xs text-zinc-500">
                    {length(entry.deck.slides)} slides
                  </p>
                </.link>
                <.link
                  navigate={entry.path <> "/remote"}
                  class="font-mono text-xs text-zinc-500 hover:text-amber-400 flex items-center gap-1 shrink-0"
                  title="phone remote"
                >
                  <.icon name="hero-device-phone-mobile" class="w-4 h-4" /> remote
                </.link>
              </div>
            </div>
          </div>
        </section>

        <p class="mt-16 font-mono text-xs text-zinc-600">
          <.link navigate={~p"/"} class="hover:text-amber-400">
            made with <span class="text-amber-400 font-bold">8</span>stal
          </.link>
        </p>
      </div>
    </main>
    """
  end
end
