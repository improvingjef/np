defmodule Np.App do
  @moduledoc """
  Adapter behaviour — every host app that wants to use the harness
  implements one of these.

  The acceptance harness itself (predicates, scenarios, interpreter,
  picker UI, persistence) is domain-agnostic. *Everything* the
  harness knows about the host app's schemas, factories, notification
  model, action handlers, and invariants goes through this behaviour.

  Wire it via:

      config :np, app: MyApp.Acceptance

  Or per-call via `opts`:

      Np.run(scenario, app: MyApp.Acceptance)
  """

  @doc """
  Resolve the Ecto repo. The interpreter calls this for every DB
  operation — the harness does not import a hard-coded repo.
  """
  @callback repo() :: module()

  @doc """
  Resolve the schema module for a domain entity type. The atom
  vocabulary is whatever scenarios say; e.g., `:tenant`, `:user`.
  """
  @callback schema_for(atom()) :: module()

  @doc """
  Build a fresh entity of the given type via the host app's factory.
  Should accept a `where:` map and produce a row that satisfies it.
  """
  @callback build_entity(atom(), map()) :: struct()

  @doc """
  Translate a `where:` key into the Ecto column / foreign-key name.
  Default conventions (e.g., `:project` → `:project_id`) are
  reasonable but adapters can customise.
  """
  @callback fk_for(atom()) :: atom()

  @doc """
  Apply a free-text search filter to a candidate query for the given
  type. The harness pages and counts; this callback decides which
  columns to ilike against.
  """
  @callback apply_search(Ecto.Query.t(), atom(), String.t() | nil) :: Ecto.Query.t()

  @doc """
  List of associations to preload for picker rendering.
  """
  @callback preloads_for(atom()) :: list()

  @doc """
  Render a one-line label for a candidate entity.
  """
  @callback label_for(atom(), struct()) :: String.t()

  @doc """
  Notification schema and field map. The MessageSent predicate uses
  these — return `nil` if the host app doesn't model notifications
  (the predicate will then always fail when used).

  Expected fields:
    * `:schema` — Ecto schema module
    * `:type_field` — atom (default `:type`)
    * `:recipient_field` — atom (default `:recipient_user_id`)
    * `:subject_field` — atom (default `:subject_id`)
    * `:inserted_at_field` — atom (default `:inserted_at`)
  """
  @callback notification() ::
              %{
                schema: module(),
                type_field: atom(),
                recipient_field: atom(),
                subject_field: atom(),
                inserted_at_field: atom()
              }
              | nil

  @doc """
  Module implementing `Np.Actions` — the host's action handler
  dispatch. The interpreter calls `actions_module().run/4` to
  execute a scenario's action in `:test` mode.
  """
  @callback actions_module() :: module()

  @doc """
  Module implementing `Np.Invariants` — the host's cross-cutting
  invariant checks.
  """
  @callback invariants_module() :: module()

  @doc """
  Resolve the active app adapter. By default reads from application
  config; tests / one-offs can pass `:app` in interpreter opts.
  """
  def resolve(opts \\ []) do
    case Keyword.get(opts, :app) do
      nil -> Application.fetch_env!(:np, :app)
      module when is_atom(module) -> module
    end
  end
end
