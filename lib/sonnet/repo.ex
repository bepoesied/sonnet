defmodule Sonnet.Repo do
  use Ecto.Repo,
    otp_app: :sonnet,
    adapter: Ecto.Adapters.Postgres
end
