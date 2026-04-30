defmodule Np.TestRepo.Migrations.CreateTestTables do
  use Ecto.Migration

  def change do
    create table(:widgets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :status, :string, default: "draft", null: false
      timestamps()
    end

    create table(:gadgets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :label, :string, null: false
      add :enabled, :boolean, default: false, null: false
      add :widget_id, references(:widgets, type: :binary_id, on_delete: :delete_all)
      timestamps()
    end

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
    create index(:acceptance_runs, [:status])
  end
end
