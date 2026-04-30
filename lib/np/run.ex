defmodule Np.Run do
  @moduledoc """
  Persisted record of a single UAT harness run.

  Captures enough to rebuild the result page after a reload and to
  build a "what got accepted lately" report later. We intentionally
  flatten predicate/invariant results into JSON-friendly maps rather
  than persisting the structs — the schema is for humans reading the
  log, not for round-tripping the constraint language.

  `operator_id` is a free-form binary id (no `belongs_to`) so this
  schema doesn't take on a hard dep on the host's user schema. Hosts
  can add their own `belongs_to` in a thin wrapper if they want.

  Migration: `mix np.gen.migration`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "acceptance_runs" do
    field :scenario_id, :string
    field :runner, Ecto.Enum, values: [:sandbox, :live]
    field :status, Ecto.Enum, values: [:running, :passed, :failed], default: :running
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :bindings_snapshot, :map, default: %{}
    field :postcondition_results, {:array, :map}, default: []
    field :invariant_results, {:array, :map}, default: []
    field :operator_id, :binary_id
    field :notes, :string

    timestamps()
  end

  @doc "Create a fresh `:running` row at the start of the act phase."
  def start_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :scenario_id,
      :runner,
      :started_at,
      :bindings_snapshot,
      :operator_id
    ])
    |> validate_required([:scenario_id, :runner, :started_at])
  end

  @doc "Update the row when the run completes (passed or failed)."
  def finish_changeset(run, attrs) do
    cast(run, attrs, [
      :status,
      :completed_at,
      :postcondition_results,
      :invariant_results,
      :notes
    ])
  end
end
