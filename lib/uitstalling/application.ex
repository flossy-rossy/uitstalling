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
        {Phoenix.PubSub, name: Uitstalling.PubSub}
      ] ++
        pipeline_child() ++
        [
          # Start to serve requests, typically the last entry
          UitstallingWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Uitstalling.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Off in tests: the pipeline drains the queue eagerly, which would race
  # tests that assert on the pending "generating…" state. Pipeline tests
  # start it manually.
  defp pipeline_child do
    if Application.get_env(:uitstalling, :start_pipeline, true) do
      [Uitstalling.Decks.Pipeline]
    else
      []
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
