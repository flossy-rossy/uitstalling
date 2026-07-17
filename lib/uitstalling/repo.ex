defmodule Uitstalling.Repo do
  use Ecto.Repo,
    otp_app: :uitstalling,
    adapter: Ecto.Adapters.Postgres
end
