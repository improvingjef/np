defmodule Mix.Tasks.Np.Playwright do
  @shortdoc "Run a scenario through the Playwright runner"

  @moduledoc """
  Drives a scenario through a real browser via Playwright.

      mix np.playwright SCENARIO_ID

  Single-process orchestration:

    1. Setup preconditions in `:sandbox` mode (factory-builds entities).
    2. Persist a `:running` row in `acceptance_runs`.
    3. Write a JSON fixture (bindings + prompt) to a tmp path.
    4. Spawn `npx playwright test --grep SCENARIO_ID` with
       `NP_FIXTURE_PATH`, `NP_RUN_ID`, `NP_SCENARIO_ID` env vars.
    5. On Playwright exit 0, verify postconditions and update the run.
       On non-zero, mark failed.

  Bindings stay in memory across the whole task, so postcondition
  verification doesn't need to rehydrate from `bindings_snapshot`.

  ## Configuration

      config :np,
        app: MyApp.Acceptance,
        scenarios: %{
          "M5-assign-translation" => MyApp.Acceptance.Scenarios.M5AssignTranslation
        }

  Optional Playwright command override (default: `npx playwright test`):

      config :np, :playwright_command, "pnpm"
      config :np, :playwright_args, ["playwright", "test"]

  ## Exit codes

  - `0` — scenario accepted (Playwright passed, postconditions held)
  - `1` — scenario rejected (Playwright passed but postconditions failed)
  - `2+` — Playwright itself failed (test errored, didn't run, etc.)
  """
  use Mix.Task

  alias Np.{Interpreter, RunContext}
  alias Np.Runners.Playwright

  @impl Mix.Task
  def run([scenario_id]) do
    Mix.Task.run("app.start")

    scenarios = Application.fetch_env!(:np, :scenarios)

    module =
      Map.get(scenarios, scenario_id) ||
        Mix.raise("unknown scenario #{inspect(scenario_id)} — known: #{inspect(Map.keys(scenarios))}")

    scenario = module.scenario()

    Mix.shell().info([:cyan, "→ ", :reset, "Setting up preconditions for #{scenario_id} (sandbox)"])

    case Interpreter.setup(scenario.preconditions, runner: :sandbox) do
      {:ok, bindings} -> drive(scenario, bindings, scenario_id)
      {:error, reason} -> Mix.raise("setup failed: #{inspect(reason)}")
    end
  end

  def run([]), do: Mix.raise("usage: mix np.playwright SCENARIO_ID")
  def run(_args), do: Mix.raise("usage: mix np.playwright SCENARIO_ID")

  defp drive(scenario, bindings, scenario_id) do
    {:ok, prompt} = Interpreter.prompt_for(scenario, bindings)
    ctx = RunContext.new(runner: :sandbox)
    {:ok, run} = Np.start_run(scenario.id, :sandbox, ctx, bindings)

    fixture_path = Playwright.write_fixture(run, scenario, bindings, prompt)
    Mix.shell().info([:cyan, "→ ", :reset, "Fixture: #{fixture_path}"])
    Mix.shell().info([:cyan, "→ ", :reset, "Spawning Playwright"])

    cmd_opts =
      [
        command: Application.get_env(:np, :playwright_command, "npx"),
        args:
          Application.get_env(:np, :playwright_args, [
            "playwright",
            "test",
            "--grep",
            scenario_id
          ])
      ]

    case Playwright.run_playwright(scenario_id, fixture_path, run.id, cmd_opts) do
      {_, 0} ->
        Mix.shell().info([:cyan, "→ ", :reset, "Playwright exit 0; verifying postconditions"])
        {:ok, result} = Interpreter.finish(scenario, bindings, run_context: ctx)
        {:ok, finished} = Np.finish_run(run, result)

        if result.passed? do
          Mix.shell().info([:green, "✓ accepted ", :reset, "(run #{finished.id})"])
          :ok
        else
          Mix.shell().error("✗ rejected — see Run #{finished.id}")
          report_failures(result)
          exit({:shutdown, 1})
        end

      {_, code} ->
        Mix.shell().error("✗ Playwright failed (exit #{code})")
        # Mark the run as failed without postcondition data so the row
        # doesn't sit in :running forever.
        {:ok, _} =
          Np.finish_run(run, %{
            passed?: false,
            postconditions: [],
            invariants: []
          })

        exit({:shutdown, max(code, 2)})
    end
  end

  defp report_failures(result) do
    failures = Enum.filter(result.postconditions, fn {_, status} -> status != :ok end)

    Enum.each(failures, fn {pred, {:fail, reason}} ->
      Mix.shell().error("    · #{Np.summarise_predicate(pred)}: #{reason}")
    end)
  end
end
