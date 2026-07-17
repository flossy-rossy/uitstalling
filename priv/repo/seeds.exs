# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Uitstalling.Repo.insert!(%Uitstalling.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Seed a demo user + the demo deck so /deck/demo works in dev.
alias Uitstalling.{Accounts, Decks}

unless Decks.exists?("demo") do
  email =
    List.first(Application.get_env(:uitstalling, :allowed_emails, [])) || "demo@uit.local"

  {:ok, user} = Accounts.register_user(email, "Demo")
  raw = Jason.decode!(File.read!(Path.join(File.cwd!(), "priv/decks/demo.json")))
  Decks.create_deck!(user.id, "demo", raw)
  IO.puts("Seeded demo deck (owner #{user.email}).")
end
