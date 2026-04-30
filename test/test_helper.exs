Application.put_env(:np, Np.TestRepo,
  database: System.get_env("NP_TEST_DB", "np_test"),
  hostname: System.get_env("NP_TEST_HOST", "localhost"),
  username: System.get_env("NP_TEST_USER", "postgres"),
  password: System.get_env("NP_TEST_PASS", "postgres"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10
)

Application.put_env(:np, :app, Np.Test.App)

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)

# Drop + recreate before the repo connects, so we don't try to talk to
# a database that doesn't exist yet.
config = Application.get_env(:np, Np.TestRepo)
_ = Ecto.Adapters.Postgres.storage_down(config)
:ok = Ecto.Adapters.Postgres.storage_up(config)

{:ok, _} = Np.TestRepo.start_link()

Ecto.Migrator.run(Np.TestRepo, "test/support/migrations", :up, all: true, log: false)
Ecto.Adapters.SQL.Sandbox.mode(Np.TestRepo, :manual)

ExUnit.start()
