defmodule Uitstalling.Writing.ProjectServer do
  @moduledoc """
  One resident GenServer per open writing project (the `DeckWorker` shape:
  Registry + DynamicSupervisor, started on demand). Two jobs:

    * **Hot cache.** The decrypted doc list, per-doc bodies, and the project
      title live here after first touch — page loads served from this cache
      skip both the DB roundtrips and the decrypt work that hurt on a
      shared-CPU machine. Every write updates the cache from its own result,
      so it never goes stale from local traffic.

    * **Write serializer.** All writes for a project funnel through one
      process, which also positions us for future shared projects: readers
      and writers across users hit the same queue. The DB CAS stays as the
      cross-node/cross-restart backstop.

  A create persists, caches the new doc's decrypted body, then replies — so
  the create→navigate→mount hop reads the doc straight from the cache with no
  decrypt, which is the win that mattered on a slow machine. (It does not
  reply before persisting: the caller often references the new id right away
  — linking a freshly-tagged element — and an id whose row didn't exist yet
  would dangle.)

  Ownership is enforced at the LiveView boundary (`Writing.owned_by?/2`)
  BEFORE anything calls in here — this server trusts its project id.
  """

  use GenServer

  alias Uitstalling.Repo
  alias Uitstalling.Writing
  alias Uitstalling.Writing.Project

  @registry Uitstalling.Writing.Registry
  @supervisor Uitstalling.Writing.ServerSupervisor

  # ----- Client -------------------------------------------------------------------

  @doc "The server for a project, started on demand."
  def ensure(project_id) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, project_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  def start_link(project_id) do
    GenServer.start_link(__MODULE__, project_id, name: via(project_id))
  end

  defp via(project_id), do: {:via, Registry, {@registry, project_id}}

  defp call(project_id, request) do
    ensure(project_id)
    GenServer.call(via(project_id), request)
  end

  @doc "The project's decrypted title (cached)."
  def title(project_id), do: call(project_id, :title)

  @doc "The docs list, `Writing.list_docs/1`-shaped (cached)."
  def list_docs(project_id), do: call(project_id, :list_docs)

  @doc "Decrypted body + seq + title for the editor (cached after first read)."
  def checkout_doc(project_id, doc_id), do: call(project_id, {:checkout_doc, doc_id})

  @doc "Create a doc, warming its cache entry; replies once persisted."
  def create_doc(project_id, kind, doc_title, opts \\ []),
    do: call(project_id, {:create_doc, kind, doc_title, opts})

  @doc "Create a plan element (a doc of kind \"element\")."
  def create_element(project_id, type, name),
    do: call(project_id, {:create_doc, "element", name, [element_type: type]})

  def apply_ops(project_id, doc_id, ops, expected_seq, actor, source \\ "editor"),
    do: call(project_id, {:apply_ops, doc_id, ops, expected_seq, actor, source})

  def undo(project_id, doc_id, expected_seq, actor),
    do: call(project_id, {:undo, doc_id, expected_seq, actor})

  def redo(project_id, doc_id, expected_seq, actor),
    do: call(project_id, {:redo, doc_id, expected_seq, actor})

  def rename_doc(project_id, doc_id, doc_title, expected_seq, actor),
    do: call(project_id, {:rename_doc, doc_id, doc_title, expected_seq, actor})

  def rename_project(project_id, new_title), do: call(project_id, {:rename_project, new_title})

  def delete_doc(project_id, doc_id), do: call(project_id, {:delete_doc, doc_id})

  @doc "Delete the project and stop its server."
  def delete_project(project_id), do: call(project_id, :delete_project)

  # ----- Server -------------------------------------------------------------------

  @impl true
  def init(project_id) do
    # Rows only — decrypts happen lazily on first use, so starting a server
    # is cheap and mount latency pays for exactly what it reads.
    {:ok, %{project: Repo.get!(Project, project_id), title: nil, docs: nil, raws: %{}}}
  end

  @impl true
  def handle_call(:title, _from, state) do
    state = put_title(state)
    {:reply, state.title, state}
  end

  def handle_call(:list_docs, _from, state) do
    state = put_docs(state)
    {:reply, state.docs, state}
  end

  def handle_call({:checkout_doc, doc_id}, _from, state) do
    case state.raws[doc_id] do
      {_raw, _seq, _title} = cached ->
        {:reply, cached, state}

      nil ->
        checked_out = Writing.checkout_doc(state.project, doc_id)
        {:reply, checked_out, put_in(state.raws[doc_id], checked_out)}
    end
  end

  def handle_call({:create_doc, kind, doc_title, opts}, _from, state) do
    id = Writing.generate_id()

    with {:ok, staged} <- Writing.stage_doc(state.project, kind, doc_title, opts),
         {:ok, meta} <- Writing.persist_staged_doc(state.project, id, staged) do
      state =
        state
        |> Map.update!(:raws, &Map.put(&1, id, {staged.raw, 1, staged.title}))
        |> Map.update!(:docs, fn
          nil -> nil
          docs -> docs ++ [meta]
        end)

      {:reply, {:ok, id}, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:apply_ops, doc_id, ops, expected_seq, actor, source}, _from, state) do
    case Writing.apply_ops(state.project, doc_id, ops, expected_seq, actor, source) do
      {:ok, new_raw, new_seq} = ok ->
        {:reply, ok, refresh_doc(state, doc_id, new_raw, new_seq)}

      other ->
        {:reply, other, state}
    end
  end

  def handle_call({:undo, doc_id, expected_seq, actor}, _from, state) do
    case Writing.undo(state.project, doc_id, expected_seq, actor) do
      {:ok, new_raw, new_seq} = ok ->
        {:reply, ok, refresh_doc(state, doc_id, new_raw, new_seq)}

      other ->
        {:reply, other, state}
    end
  end

  def handle_call({:redo, doc_id, expected_seq, actor}, _from, state) do
    case Writing.redo(state.project, doc_id, expected_seq, actor) do
      {:ok, new_raw, new_seq} = ok ->
        {:reply, ok, refresh_doc(state, doc_id, new_raw, new_seq)}

      other ->
        {:reply, other, state}
    end
  end

  def handle_call({:rename_doc, doc_id, doc_title, expected_seq, actor}, _from, state) do
    case Writing.rename_doc(state.project, doc_id, doc_title, expected_seq, actor) do
      {:ok, new_title, new_seq} = ok ->
        state =
          state
          |> update_raw(doc_id, fn {raw, _seq, _title} -> {raw, new_seq, new_title} end)
          |> update_doc_meta(doc_id, &%{&1 | title: new_title, seq: new_seq})

        {:reply, ok, state}

      other ->
        {:reply, other, state}
    end
  end

  def handle_call({:rename_project, new_title}, _from, state) do
    case Writing.rename_project(state.project, new_title) do
      :ok -> {:reply, :ok, %{state | title: nil, project: Repo.get!(Project, state.project.id)}}
      other -> {:reply, other, state}
    end
  end

  def handle_call({:delete_doc, doc_id}, _from, state) do
    :ok = Writing.delete_doc(state.project, doc_id)

    state = %{
      state
      | raws: Map.delete(state.raws, doc_id),
        docs: state.docs && Enum.reject(state.docs, &(&1.id == doc_id))
    }

    {:reply, :ok, state}
  end

  def handle_call(:delete_project, _from, state) do
    :ok = Writing.delete_project(state.project)
    {:stop, :normal, :ok, state}
  end

  # ----- Cache upkeep -----------------------------------------------------------------

  defp put_title(%{title: nil} = state),
    do: %{state | title: Writing.project_title(state.project)}

  defp put_title(state), do: state

  defp put_docs(%{docs: nil} = state), do: %{state | docs: Writing.list_docs(state.project)}
  defp put_docs(state), do: state

  defp refresh_doc(state, doc_id, new_raw, new_seq) do
    words = Writing.count_words(new_raw)

    state
    |> update_raw(doc_id, fn {_raw, _seq, title} -> {new_raw, new_seq, title} end)
    |> update_doc_meta(doc_id, &%{&1 | seq: new_seq, word_count: words})
  end

  # Cache-only updates: a miss (never checked out / list never loaded) is
  # simply nothing to keep fresh.
  defp update_raw(state, doc_id, fun) do
    case state.raws[doc_id] do
      nil -> state
      entry -> put_in(state.raws[doc_id], fun.(entry))
    end
  end

  defp update_doc_meta(%{docs: nil} = state, _doc_id, _fun), do: state

  defp update_doc_meta(state, doc_id, fun) do
    %{
      state
      | docs: Enum.map(state.docs, fn doc -> if doc.id == doc_id, do: fun.(doc), else: doc end)
    }
  end
end
