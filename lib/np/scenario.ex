defmodule Np.Scenario do
  @moduledoc """
  A SAFE scenario rendered as data.

  - `id` — stable identifier for cross-referencing with the host app's
    scenario catalog
  - `title`, `narrative` — what the harness shows the operator
  - `preconditions` — list of `Np.Predicate.Bind` (and friends) that
    the interpreter materialises before running the action
  - `action` — `%Np.Action{}` named handler from the host app's
    actions module (see `Np.Actions`)
  - `postconditions` — list of predicates verified after the action
  - `invariants` — names of host invariants to also check after the
    action; defaults to `:standard` (the cross-cutting set)
  """
  @enforce_keys [:id, :title, :preconditions, :action, :postconditions]
  defstruct [
    :id,
    :title,
    :narrative,
    :preconditions,
    :action,
    :postconditions,
    invariants: :standard
  ]
end

defmodule Np.Action do
  @moduledoc """
  An action, by name, with resolved-against-bindings inputs. Handlers
  live in the host app's actions module (see `Np.Actions`).

  - `name` — registry key dispatched in `:test` mode
  - `actor` — `Np.Ref.t()` resolved from bindings (often the same as
    the user the operator signs in as during UAT)
  - `inputs` — map of `key => Ref | literal`; resolved before dispatch
  - `prompt` — for `:uat` mode, a 1-arg fn taking the resolved
    bindings and returning `%{title, body, goto}`. The harness LV
    renders this and waits for the operator to perform the action
    themselves
  """
  @enforce_keys [:name]
  defstruct [:name, :actor, inputs: %{}, prompt: nil]
end
