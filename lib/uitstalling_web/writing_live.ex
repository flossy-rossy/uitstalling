defmodule UitstallingWeb.WritingLive do
  @moduledoc """
  The writing shelf: a user's projects. Private end to end — there is no
  public writing surface, so everything here requires a signed-in author.
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
         |> redirect(to: ~p"/auth/login?return_to=/write")}

      not Accounts.can_author?(user) ->
        {:ok,
         socket |> put_flash(:error, "Writing is for registered accounts") |> redirect(to: ~p"/")}

      true ->
        {:ok,
         assign(socket,
           page_title: "Writing",
           projects: Writing.list_projects(user.id),
           create_error: nil
         )}
    end
  end

  def handle_event("create_project", %{"title" => title}, socket) do
    case Writing.create_project(socket.assigns.current_user.id, title) do
      {:ok, id} ->
        {:noreply, push_navigate(socket, to: ~p"/write/#{id}")}

      {:error, [error]} ->
        {:noreply, assign(socket, create_error: error)}
    end
  end

  def render(assigns) do
    assigns = assign(assigns, :palette, WritingComponents.page_theme("paper"))

    ~H"""
    <main class={["min-h-dvh px-8 sm:px-16 py-16 font-literata", @palette.bg, @palette.ink]}>
      <div class="max-w-3xl mx-auto">
        <header class="flex items-end justify-between flex-wrap gap-6">
          <div>
            <p class={["font-mono text-sm tracking-widest uppercase", @palette.accent]}>
              UIT · writing
            </p>
            <h1 class="mt-4 text-5xl font-bold leading-tight">Your shelf.</h1>
          </div>
          <.link navigate={~p"/"} class={["font-mono text-xs", @palette.muted, "hover:underline"]}>
            ← presentations
          </.link>
        </header>

        <form phx-submit="create_project" class="mt-12 flex gap-3 max-w-xl">
          <input
            type="text"
            name="title"
            required
            placeholder="A title to start a new project…"
            autocomplete="off"
            class={[
              "flex-1 rounded-lg px-4 py-3 bg-transparent border",
              @palette.rule,
              "placeholder:opacity-50 focus:outline-none focus:ring-2 focus:ring-amber-600/40"
            ]}
          />
          <button
            type="submit"
            class="px-6 py-3 rounded-lg bg-stone-900 text-stone-50 font-semibold hover:bg-stone-700 transition"
          >
            + New project
          </button>
        </form>
        <p :if={@create_error} class="mt-2 text-sm text-red-700">{@create_error}</p>

        <section class="mt-14">
          <p :if={@projects == []} class={["text-lg", @palette.muted]}>
            Nothing on the shelf yet — every novel starts with a title (or a working one).
          </p>

          <div class="grid gap-4">
            <.link
              :for={project <- @projects}
              navigate={~p"/write/#{project.id}"}
              class={[
                "group rounded-xl border p-6 transition",
                @palette.rule,
                @palette.card,
                @palette.hover
              ]}
            >
              <div class="flex items-start justify-between gap-4">
                <p class="text-2xl font-semibold leading-snug group-hover:underline decoration-1 underline-offset-4">
                  {project.title}
                </p>
                <span class={[
                  "mt-1 inline-block w-3 h-3 rounded-full shrink-0 ring-1",
                  WritingComponents.swatch(project.theme)
                ]}></span>
              </div>
              <p class={["mt-3 font-mono text-xs", @palette.muted]}>
                {project.chapters} {if project.chapters == 1, do: "chapter", else: "chapters"} · {project.words} words
                · {WritingComponents.font_label(project.font)}
              </p>
            </.link>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
