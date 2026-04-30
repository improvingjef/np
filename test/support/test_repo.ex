defmodule Np.TestRepo do
  use Ecto.Repo,
    otp_app: :np,
    adapter: Ecto.Adapters.Postgres
end
