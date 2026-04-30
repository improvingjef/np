defmodule Np.Predicate do
  @moduledoc """
  Closed set of predicate structs — the constraint language vocabulary.

  Adding a new predicate here means deciding it's a primitive of the
  domain. Most things are expressible as combinations of the existing
  ones (count + attribute + relationship); resist the urge to add
  `WhateverSpecificThing` until the workaround is unbearable.

  Naming convention: each predicate is itself a struct under this
  module, so scenarios read as `%Predicate.Bind{...}`. The interpreter
  dispatches on struct type.
  """

  alias Np.Ref

  defmodule Bind do
    @moduledoc """
    Precondition: bind an entity of `type` to `name`. The `mode`
    determines how the entity arrives:

    - `:create` — factory-build a fresh entity (default for sandbox
      runs; right for dev demos and CI)
    - `:find` — must already exist matching `where`; raise if none
    - `:find_or_create` — find existing matching `where`; create if
      not found
    - `:pick` — show the operator a paginated, searchable picker
      filtered by `where` (resolved against earlier bindings); they
      choose at run time

    `:label` is the human-readable string the picker UI shows above
    the dropdown ("Pick the tenant to test against").

    The runner can downgrade `:pick` to `:create` — sandbox mode skips
    pickers entirely (see `Interpreter.setup/2` `:runner` option).
    """
    @enforce_keys [:name, :type]
    defstruct [
      :name,
      :type,
      :label,
      where: %{},
      mode: :create
    ]
  end

  defmodule Exists do
    @moduledoc """
    Postcondition: at least one entity of `type` matches `where`.
    Optionally `bind` the matched entity to a name for use by later
    predicates in the same postcondition list.

    `since:` (optional) filters by `inserted_at >= since`. In live mode
    this is auto-populated from the run's `started_at` so a predicate
    like "an audit log exists for this user" doesn't pass on history
    from real production work.
    """
    @enforce_keys [:type]
    defstruct [:type, where: %{}, bind: nil, since: nil]
  end

  defmodule Count do
    @moduledoc """
    Postcondition: the count of `type` entities matching `where`
    satisfies `op n` (e.g., `op: :==, n: 3`).

    `since:` (optional) filters by `inserted_at >= since`. In live UAT
    against staged data, this is the difference between counting "since
    this run started" and "since the dawn of time."
    """
    @enforce_keys [:type, :op, :n]
    defstruct [:type, :op, :n, where: %{}, since: nil]
  end

  defmodule Attribute do
    @moduledoc """
    Postcondition: the attribute `key` on the entity referenced by
    `ref` satisfies `op value` (e.g., `op: :==`, `op: :!=`,
    `op: :is_set`, `op: :is_nil`).
    """
    @enforce_keys [:ref, :key, :op]
    defstruct [:ref, :key, :op, :value]
  end

  defmodule Relationship do
    @moduledoc """
    Postcondition: the entity at `from` is associated with the entity
    at `to` via Ecto association `assoc`.
    """
    @enforce_keys [:from, :assoc, :to]
    defstruct [:from, :assoc, :to]
  end

  defmodule MessageSent do
    @moduledoc """
    Postcondition: a notification of the given `type` exists for
    recipient `to` (a Ref) about subject `about` (a Ref). The host
    app's `Np.App.notification/0` callback wires this up to whatever
    notification schema the app uses.

    `since:` (optional) filters by `inserted_at >= since` — same
    semantics as Count.
    """
    @enforce_keys [:type]
    defstruct [:type, :to, :about, since: nil]
  end

  defmodule ForAll do
    @moduledoc """
    Invariant: for every entity matching `where`, `assert` (a list of
    predicates evaluated in the entity's binding) holds.
    """
    @enforce_keys [:type, :assert]
    defstruct [:type, :assert, where: %{}, bind_as: :it]
  end

  defmodule None do
    @moduledoc """
    Invariant / postcondition: zero entities match `where`. Useful for
    "no superseded log was double-retried" sorts of properties.

    `since:` (optional) filters by `inserted_at >= since`.
    """
    @enforce_keys [:type]
    defstruct [:type, where: %{}, since: nil]
  end

  ## Constructors (sugar)

  def bind(name, type, where \\ %{}, opts \\ []) do
    %Bind{
      name: name,
      type: type,
      where: where,
      mode: Keyword.get(opts, :mode, :create),
      label: Keyword.get(opts, :label)
    }
  end

  @doc "Sugar for `bind(name, type, where, mode: :pick, label: label)`."
  def pick(name, type, where \\ %{}, label \\ nil) do
    bind(name, type, where, mode: :pick, label: label)
  end

  @doc "Sugar for `bind(name, type, where, mode: :find)`."
  def find(name, type, where \\ %{}) do
    bind(name, type, where, mode: :find)
  end

  def exists(type, where \\ %{}, bind \\ nil),
    do: %Exists{type: type, where: where, bind: bind}

  def count(type, op, n, where \\ %{}),
    do: %Count{type: type, op: op, n: n, where: where}

  def attribute(ref, key, op, value \\ nil) do
    %Attribute{ref: as_ref(ref), key: key, op: op, value: value}
  end

  def relationship(from, assoc, to) do
    %Relationship{from: as_ref(from), assoc: assoc, to: as_ref(to)}
  end

  def message_sent(type, to: to, about: about) do
    %MessageSent{type: type, to: as_ref(to), about: as_ref(about)}
  end

  def none(type, where \\ %{}), do: %None{type: type, where: where}

  defp as_ref(%Ref{} = r), do: r
  defp as_ref(name) when is_atom(name), do: Ref.new(name)
end
