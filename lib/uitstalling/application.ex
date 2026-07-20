defmodule Uitstalling.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        UitstallingWeb.Telemetry,
        Uitstalling.Repo,
        {DNSCluster, query: Application.get_env(:uitstalling, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Uitstalling.PubSub},
        # Per-deck request workers, started on demand via DeckWorker.kick/1
        {Registry, keys: :unique, name: Uitstalling.Decks.Registry},
        {DynamicSupervisor, name: Uitstalling.Decks.WorkerSupervisor, strategy: :one_for_one}
      ] ++
        chromic_child() ++
        boot_drain_child() ++
        [
          # Start to serve requests, typically the last entry
          UitstallingWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Uitstalling.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Off in tests: workers drain the queue eagerly, which would race tests
  # that assert on the pending "generating…" state. Worker tests start
  # workers manually. In dev/prod this one-shot task resumes any decks with
  # requests left unfinished by the previous run.
  defp boot_drain_child do
    if Application.get_env(:uitstalling, :start_pipeline, true) do
      [{Task, &Uitstalling.Decks.DeckWorker.kick_unfinished/0}]
    else
      []
    end
  end

  # Headless Chrome for PDF export. Configured in runtime.exs for dev/prod;
  # absent in test, where Decks.Pdf is stubbed by a fake.
  defp chromic_child do
    case Application.get_env(:uitstalling, :chromic_pdf) do
      nil -> []
      opts -> [{ChromicPDF, opts}]
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UitstallingWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
