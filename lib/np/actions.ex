defmodule Np.Actions do
  @moduledoc """
  Behaviour for the host app's action-handler registry.

  Each scenario action has a `name`; the interpreter dispatches that
  name to the host's actions module via `run/4`. Handlers return:

      {:ok, new_bindings_map} | {:error, reason}

  New bindings are merged into the scenario's binding map and become
  available to postcondition predicates (so e.g. `place_order` can
  return `%{placed_order: updated}` and a later
  `attribute(placed_order, :status, :==, "placed")` resolves cleanly).

  Implement this in your app:

      defmodule MyApp.Acceptance.Actions do
        @behaviour Np.Actions

        @impl true
        def run(:place_order, actor, inputs, _bindings) do
          # ...
          {:ok, %{placed_order: ...}}
        end

        def run(name, _actor, _inputs, _bindings),
          do: {:error, {:unknown_action, name}}
      end

  Then point at it from your `Np.App` adapter:

      def actions_module, do: MyApp.Acceptance.Actions
  """

  @callback run(name :: atom(), actor :: any(), inputs :: map(), bindings :: map()) ::
              {:ok, map()} | {:error, any()}
end
