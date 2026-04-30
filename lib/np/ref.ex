defmodule Np.Ref do
  @moduledoc """
  A symbolic reference to an entity bound earlier in the same scenario.

      ref(:tenant)         # in a precondition: bind result to :tenant
      ref(:tenant)         # in a later predicate: resolve to that entity

  References are resolved by the interpreter against a `bindings` map.
  Unknown names fail loudly at run time.
  """

  defstruct [:name]

  @type t :: %__MODULE__{name: atom()}

  @doc "Construct a reference to a previously-bound entity."
  def new(name) when is_atom(name), do: %__MODULE__{name: name}
end
