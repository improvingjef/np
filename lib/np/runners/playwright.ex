defmodule Np.Runners.Playwright do
  @moduledoc """
  Third runner — drives a scenario through a real browser via
  Playwright.

  The shape:

  1. **Elixir side (np)** — setup preconditions in `:sandbox` mode,
     persist a `:running` Run row, write a JSON fixture file, return
     the fixture path + run id.
  2. **JS side (host)** — a Playwright test reads the fixture (via
     `NP_FIXTURE_PATH` env var), drives the browser through the
     scenario, exits 0/non-zero.
  3. **Elixir side (np)** — on Playwright exit 0, run
     `Interpreter.finish/3` against the in-memory bindings (no
     rehydration needed because we never released them) and update
     the Run row with the verdict.

  The orchestration lives in `mix np.playwright`. This module holds
  the pure pieces (fixture serialization, command-spawning) so they're
  testable.

  ## Fixture format

  A JSON file written to a tmp path. The Playwright test loads it
  via `priv/js/np.fixture.js`:

      {
        "run_id": "01JK...",
        "scenario_id": "M5-assign-translation",
        "bindings": {
          "tenant":     {"type": "tenant",     "id": "...", "display": {"name": "...", "slug": "..."}},
          "translator": {"type": "user",       "id": "...", "display": {"email": "..."}},
          ...
        },
        "prompt": {
          "title": "Assign the translation to ...",
          "body": "1. Sign in as ...",
          "goto": "/projects/.../translations"
        }
      }
  """

  @display_keys [:name, :title, :label, :email, :slug, :code]

  @doc """
  Serialize a bindings map to the fixture form. Each entity becomes
  `{type, id, display}`; only the display keys with set values are
  retained, so the JSON stays small and readable.
  """
  def serialize_bindings(bindings) do
    Map.new(bindings, fn {name, entity} ->
      {to_string(name), serialize_entity(entity)}
    end)
  end

  defp serialize_entity(%_{id: id} = entity) do
    type =
      entity.__struct__
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    display =
      entity
      |> Map.take(@display_keys)
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)

    %{"type" => type, "id" => id, "display" => display}
  end

  @doc """
  Build the full fixture map.
  """
  def build_fixture(run, scenario, bindings, prompt) do
    %{
      "run_id" => run.id,
      "scenario_id" => scenario.id,
      "bindings" => serialize_bindings(bindings),
      "prompt" => prompt
    }
  end

  @doc """
  Write the fixture to a tmp file, return the path.
  """
  def write_fixture(run, scenario, bindings, prompt) do
    fixture = build_fixture(run, scenario, bindings, prompt)
    path = Path.join(System.tmp_dir!(), "np-fixture-#{run.id}.json")
    File.write!(path, Jason.encode!(fixture))
    path
  end

  @doc """
  Invoke `npx playwright test --grep <scenario_id>` with the
  fixture path passed via env vars. Returns `{output, exit_code}`.

  Defaults can be overridden via opts:

  - `:command` — defaults to `"npx"`
  - `:args` — defaults to `["playwright", "test", "--grep", scenario_id]`
  - `:env` — additional env vars merged with the np ones
  - `:cd` — working directory (defaults to host project root)
  """
  def run_playwright(scenario_id, fixture_path, run_id, opts \\ []) do
    cmd = Keyword.get(opts, :command, "npx")

    args =
      Keyword.get(opts, :args, ["playwright", "test", "--grep", scenario_id])

    extra_env = Keyword.get(opts, :env, [])
    cd = Keyword.get(opts, :cd, File.cwd!())

    System.cmd(cmd, args,
      env:
        [
          {"NP_FIXTURE_PATH", fixture_path},
          {"NP_RUN_ID", run_id},
          {"NP_SCENARIO_ID", scenario_id}
        ] ++ extra_env,
      cd: cd,
      into: IO.stream()
    )
  end
end
