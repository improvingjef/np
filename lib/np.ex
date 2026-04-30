defmodule Np do
  @moduledoc """
  No problem. Acceptance testing for humans.

  ## What this is

  A small DSL for SAFE scenarios (Succeeds / Advances / Fails / Errors)
  rendered as data, plus an interpreter that runs them three ways:

    * **Test runner** — ExUnit calls `Np.run/2`; preconditions get
      factory-built, the action handler runs, postconditions are
      verified.
    * **UAT runner** — a LiveView (`Np.LiveView`) walks an operator
      through preconditions (sandbox: factory-built; live: pick real
      entities through paginated/searchable dropdowns), shows a
      prompt for the action, then verifies postconditions.
    * **Live drift** — the same predicates run against the live
      database with no scenario context; failures are spec drift.

  Scenarios are *data*. Predicates are a closed vocabulary
  (`Np.Predicate.{Bind,Exists,Count,Attribute,Relationship,
  MessageSent,ForAll,None}`). Adding a new primitive is rare.

  ## Setup

      # config/config.exs
      config :np, app: MyApp.Acceptance

      # lib/my_app/acceptance.ex
      defmodule MyApp.Acceptance do
        @behaviour Np.App

        @impl true
        def repo, do: MyApp.Repo

        @impl true
        def schema_for(:user), do: MyApp.Accounts.User
        # ...

        @impl true
        def actions_module, do: MyApp.Acceptance.Actions

        @impl true
        def invariants_module, do: MyApp.Acceptance.Invariants

        # ...
      end

      # mix np.gen.migration
      # mix ecto.migrate

  See the README for a full walkthrough.
  """

  alias Np.{Interpreter, Predicate, Run, Scenario}

  @doc """
  Run a scenario end-to-end. Returns `{:ok, %{bindings,
  postconditions, invariants, passed?}}` regardless of pass/fail;
  callers inspect the result map to render UI / fail tests.
  """
  def run(%Scenario{} = scenario, opts \\ []) do
    Interpreter.run(scenario, opts)
  end

  @doc """
  Persist a `:running` row at the start of the act phase. The LV
  uses the returned id to update the row when the run completes.
  """
  def start_run(scenario_id, runner, ctx, bindings, operator_id \\ nil, opts \\ []) do
    repo = Np.App.resolve(opts).repo()

    %{
      scenario_id: scenario_id,
      runner: runner,
      started_at: ctx.started_at,
      bindings_snapshot: bindings_snapshot(bindings),
      operator_id: operator_id
    }
    |> Run.start_changeset()
    |> repo.insert()
  end

  @doc """
  Update a previously started run with the verify result. Pass the
  `Interpreter.finish/3` result map; the schema fields are derived
  from it.
  """
  def finish_run(%Run{} = run, result, opts \\ []) do
    repo = Np.App.resolve(opts).repo()
    status = if result.passed?, do: :passed, else: :failed

    run
    |> Run.finish_changeset(%{
      status: status,
      completed_at: DateTime.utc_now(),
      postcondition_results: serialize_postconditions(result.postconditions),
      invariant_results: serialize_invariants(result.invariants)
    })
    |> repo.update()
  end

  @doc "Get a persisted run by id (for the result-page reload path)."
  def get_run(id, opts \\ []) do
    Np.App.resolve(opts).repo().get(Run, id)
  end

  ## Serialization

  defp bindings_snapshot(bindings) do
    Map.new(bindings, fn {name, %_{} = entity} ->
      {to_string(name),
       %{
         "type" => entity.__struct__ |> Module.split() |> List.last(),
         "id" => entity.id
       }}
    end)
  end

  defp serialize_postconditions(results) do
    Enum.map(results, fn {pred, status} ->
      %{
        "predicate" => summarise_predicate(pred),
        "status" => status_label(status),
        "reason" => status_reason(status)
      }
    end)
  end

  defp serialize_invariants(results) do
    Enum.map(results, fn {{:invariant, name}, status} ->
      %{
        "name" => to_string(name),
        "status" => status_label(status),
        "reason" => status_reason(status)
      }
    end)
  end

  defp status_label(:ok), do: "ok"
  defp status_label({:fail, _}), do: "fail"

  defp status_reason(:ok), do: nil
  defp status_reason({:fail, reason}), do: reason

  @doc """
  Render a one-line, human-readable summary of a predicate. Used by
  the LV result page and the persisted run's `postcondition_results`
  field, so both in-session results and reload-from-DB look the same.
  """
  def summarise_predicate(%Predicate.Attribute{ref: r, key: k, op: op, value: v}) do
    "#{r.name}.#{k} #{op} #{inspect(v)}"
  end

  def summarise_predicate(%Predicate.Relationship{from: f, assoc: a, to: t}) do
    "#{f.name}.#{a} → #{t.name}"
  end

  def summarise_predicate(%Predicate.MessageSent{type: t, to: to, about: about}) do
    "#{t} notification → #{to.name}#{if about, do: " about #{about.name}", else: ""}"
  end

  def summarise_predicate(%Predicate.Count{type: t, op: op, n: n}) do
    "count(#{t}) #{op} #{n}"
  end

  def summarise_predicate(%Predicate.Exists{type: t}), do: "exists(#{t})"
  def summarise_predicate(%Predicate.None{type: t}), do: "none(#{t})"
  def summarise_predicate(other), do: inspect(other)
end
