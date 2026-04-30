defmodule Np.Invariants do
  @moduledoc """
  Behaviour for cross-cutting properties expected to hold across every
  scenario's post-state.

  Each invariant is a list of `Np.Predicate.*` structs. The interpreter
  evaluates them after `verify/3` completes; failures are reported
  alongside postcondition failures.

  The same predicates can run against the live database via
  `live_drift/0` to detect history that's slipped out of spec.

  Implement this in your app:

      defmodule MyApp.Acceptance.Invariants do
        @behaviour Np.Invariants

        alias Np.Predicate

        @impl true
        def standard do
          %{
            "every notification has a recipient_user_id" => [
              %Predicate.ForAll{
                type: :notification,
                where: %{},
                assert: [Predicate.attribute(:it, :recipient_user_id, :is_set)]
              }
            ]
          }
        end
      end

  Then point at it from your `Np.App` adapter:

      def invariants_module, do: MyApp.Acceptance.Invariants

  The harness handles `check_standard/1`, `check/2`, and `live_drift/1`
  on top of `standard/0` — you only have to define the catalog.
  """

  @doc """
  Catalog of invariants. Returns a map of `name (binary) =>
  [%Predicate.* {}]`.
  """
  @callback standard() :: %{String.t() => [struct()]}

  alias Np.Interpreter

  @doc """
  Run every standard invariant against the given bindings. The
  interpreter calls this after `verify/3`.
  """
  def check_standard(bindings, ctx \\ nil, opts \\ []) do
    module = invariants_module(opts)

    Enum.flat_map(module.standard(), fn {name, preds} ->
      Enum.map(preds, fn pred ->
        case Interpreter.evaluate(pred, bindings, ctx) do
          {:ok, _} -> {{:invariant, name}, :ok}
          {:fail, reason} -> {{:invariant, name}, {:fail, reason}}
        end
      end)
    end)
  end

  @doc """
  Run a single named invariant against the given bindings.
  """
  def check(name, bindings, ctx \\ nil, opts \\ []) when is_binary(name) do
    module = invariants_module(opts)

    case Map.fetch(module.standard(), name) do
      {:ok, preds} ->
        Enum.map(preds, fn pred ->
          case Interpreter.evaluate(pred, bindings, ctx) do
            {:ok, _} -> {{:invariant, name}, :ok}
            {:fail, reason} -> {{:invariant, name}, {:fail, reason}}
          end
        end)

      :error ->
        [{{:invariant, name}, {:fail, "unknown invariant"}}]
    end
  end

  @doc """
  Run every standard invariant against the live database (no scenario
  context). Drift detection.
  """
  def live_drift(opts \\ []) do
    module = invariants_module(opts)

    Enum.flat_map(module.standard(), fn {name, preds} ->
      Enum.map(preds, fn pred ->
        case Interpreter.evaluate(pred, %{}) do
          {:ok, _} -> {name, :ok}
          {:fail, reason} -> {name, {:fail, reason}}
        end
      end)
    end)
  end

  defp invariants_module(opts) do
    case Keyword.get(opts, :invariants_module) do
      nil -> Np.App.resolve(opts).invariants_module()
      module -> module
    end
  end
end
