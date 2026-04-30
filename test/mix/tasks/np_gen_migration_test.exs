defmodule Mix.Tasks.Np.Gen.MigrationTest do
  use ExUnit.Case, async: false

  # Exercises the generator's source-text construction (the pure
  # piece) without needing a real Mix project layout.
  describe "migration_source/1 (private — accessed via call_private/2)" do
    test "module name is namespaced under the resolved repo's module" do
      assert source = call_private(:migration_source, [MyApp.Repo])
      assert source =~ "defmodule MyApp.Repo.Migrations.CreateAcceptanceRuns do"
    end

    test "operator_id column is :string (host-id-agnostic)" do
      assert source = call_private(:migration_source, [MyApp.Repo])
      assert source =~ "add :operator_id, :string"
      refute source =~ "add :operator_id, :binary_id"
    end

    test "still generates the expected indexes" do
      assert source = call_private(:migration_source, [MyApp.Repo])
      assert source =~ "create index(:acceptance_runs, [:scenario_id, :inserted_at])"
      assert source =~ "create index(:acceptance_runs, [:operator_id])"
      assert source =~ "create index(:acceptance_runs, [:status])"
    end
  end

  # Helper: call a private function on Mix.Tasks.Np.Gen.Migration.
  # Mix tasks aren't structured for unit-testing the template builder
  # in isolation, so we do this dance.
  defp call_private(fun, args) do
    apply(Mix.Tasks.Np.Gen.Migration, fun, args)
  end
end
