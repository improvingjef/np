defmodule Mix.Tasks.Np.Gen.Migration do
  @shortdoc "Generates the acceptance_runs migration for Np"

  @moduledoc """
  Generates a migration that creates the `acceptance_runs` table —
  the persisted ledger of every UAT harness run.

      mix np.gen.migration

  The migration file is written into the host app's
  `priv/repo/migrations/` with a fresh timestamp.

  Options:

      --repo MODULE   Specify the repo (default: the host app's
                      configured Ecto repo)
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [repo: :string])

    repo = resolve_repo(opts[:repo])
    migrations_path = migrations_path(repo)
    File.mkdir_p!(migrations_path)

    timestamp = timestamp()
    filename = "#{timestamp}_create_acceptance_runs.exs"
    path = Path.join(migrations_path, filename)

    if File.exists?(path) do
      Mix.raise("migration already exists: #{path}")
    end

    File.write!(path, migration_source())
    Mix.shell().info([:green, "* creating ", :reset, Path.relative_to_cwd(path)])
    :ok
  end

  defp resolve_repo(nil) do
    Mix.Project.config()
    |> Keyword.get(:app)
    |> Application.get_env(:ecto_repos, [])
    |> List.first() ||
      Mix.raise("""
      No Ecto repo configured for this project. Pass --repo MyApp.Repo,
      or set `:ecto_repos` in your Mix.Project config.
      """)
  end

  defp resolve_repo(string) when is_binary(string), do: Module.concat([string])

  defp migrations_path(repo) do
    base = Path.dirname(repo.config()[:priv] || "priv/#{Macro.underscore(repo)}")
    Path.join([base, "repo", "migrations"])
  rescue
    _ -> Path.join([File.cwd!(), "priv", "repo", "migrations"])
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, hh, mm, ss])
    |> IO.iodata_to_binary()
  end

  defp migration_source do
    """
    defmodule Repo.Migrations.CreateAcceptanceRuns do
      @moduledoc \"\"\"
      Persisted record of every Np UAT harness run.
      \"\"\"
      use Ecto.Migration

      def change do
        create table(:acceptance_runs, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :scenario_id, :string, null: false
          add :runner, :string, null: false
          add :status, :string, null: false, default: "running"
          add :started_at, :utc_datetime_usec, null: false
          add :completed_at, :utc_datetime_usec
          add :bindings_snapshot, :map, default: %{}, null: false
          add :postcondition_results, {:array, :map}, default: []
          add :invariant_results, {:array, :map}, default: []
          add :operator_id, :binary_id
          add :notes, :text
          timestamps()
        end

        create index(:acceptance_runs, [:scenario_id, :inserted_at])
        create index(:acceptance_runs, [:operator_id])
        create index(:acceptance_runs, [:status])
      end
    end
    """
  end
end
