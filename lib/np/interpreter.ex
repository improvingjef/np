defmodule Np.Interpreter do
  @moduledoc """
  Compiles a `Np.Scenario` into Repo / factory / action calls and
  produces a per-predicate result list.

  Three responsibilities, separated for testability:

    * `setup/2` — walk `preconditions`, materialise each `Bind`,
      return a `bindings` map `%{name => %Schema{}}`
    * `act/2` — dispatch the named action with bindings + resolved
      inputs (via the host's `Np.Actions` module)
    * `verify/3` — walk `postconditions`, evaluate each predicate
      against the post-state, return `[{predicate, :ok | {:fail,
      reason}}]`

  `run/2` orchestrates all three plus invariant checks.

  All host-app knowledge (schema dispatch, factories, search, labels,
  notification model, action handlers, invariants) is delegated to
  the configured `Np.App` adapter — this module is reusable across
  apps with no edits.
  """

  import Ecto.Query

  alias Np.{Action, App, Ref, RunContext, Scenario}

  alias Np.Predicate.{
    Attribute,
    Bind,
    Count,
    Exists,
    ForAll,
    MessageSent,
    None,
    Relationship
  }

  ## Public API

  @doc """
  End-to-end run in `:test` mode (setup → action handler → verify).
  """
  def run(%Scenario{} = scenario, opts \\ []) do
    with {:ok, bindings} <- setup(scenario.preconditions, opts),
         {:ok, action_bindings} <- act(scenario.action, bindings, opts) do
      finish(scenario, Map.merge(bindings, action_bindings), opts)
    end
  end

  @doc "Render the UAT prompt for a scenario with the resolved bindings map."
  def prompt_for(%Scenario{action: %Action{prompt: nil}}, _bindings),
    do: {:error, :no_prompt}

  def prompt_for(%Scenario{action: %Action{prompt: fun}}, bindings)
      when is_function(fun, 1) do
    {:ok, fun.(bindings)}
  end

  @doc """
  Skip the action phase (the human performed it themselves) and jump
  straight to verify + invariants. The UAT harness calls this when
  the operator clicks "I did it".
  """
  def finish(%Scenario{} = scenario, bindings, opts \\ []) do
    ctx = run_context(opts)
    results = verify(scenario.postconditions, bindings, ctx, opts)
    invariant_results = check_invariants(scenario, bindings, ctx, opts)

    {:ok,
     %{
       scenario_id: scenario.id,
       bindings: bindings,
       postconditions: results,
       invariants: invariant_results,
       passed?: all_ok?(results) and all_ok?(invariant_results)
     }}
  end

  defp run_context(%RunContext{} = ctx), do: ctx

  defp run_context(opts) when is_list(opts) do
    case Keyword.get(opts, :run_context) do
      %RunContext{} = ctx -> ctx
      nil -> RunContext.new(opts)
    end
  end

  ## Setup

  @doc """
  Run preconditions in setup. Behavior depends on the `:runner` option:

  - `:sandbox` (default) — every Bind, regardless of mode, factory-creates.
  - `:live` — `:create`/`:find_or_create` run normally; `:find` looks
    up; `:pick` is *deferred* and reported as a remaining step.
  """
  def setup(preconditions, opts \\ []) when is_list(preconditions) do
    runner = Keyword.get(opts, :runner, :sandbox)
    seed = Keyword.get(opts, :seed_bindings, %{})

    try do
      do_setup(preconditions, seed, runner, [], opts)
    rescue
      e -> {:error, {:setup_failed, Exception.message(e)}}
    end
  end

  defp do_setup([], bindings, _runner, [], _opts), do: {:ok, bindings}

  defp do_setup([], bindings, _runner, picks_pending, _opts),
    do: {:picks_required, bindings, Enum.reverse(picks_pending)}

  defp do_setup([%Bind{name: name} = bind | rest], bindings, runner, picks_pending, opts) do
    effective_mode = effective_mode(bind.mode, runner)

    cond do
      Map.has_key?(bindings, name) ->
        # Pre-seeded by the host (e.g. the LV grafted in the operator
        # and their tenant before calling setup). Skip materialisation;
        # use what's already there.
        do_setup(rest, bindings, runner, picks_pending, opts)

      effective_mode == :pick ->
        do_setup(rest, bindings, runner, [bind | picks_pending], opts)

      picks_pending != [] ->
        do_setup(rest, bindings, runner, [bind | picks_pending], opts)

      true ->
        new_bindings = materialise(bind, bindings, effective_mode, opts)
        do_setup(rest, new_bindings, runner, [], opts)
    end
  end

  @doc "Resume setup after the operator has resolved every pending pick."
  def resume_setup(remaining_binds, bindings, opts \\ []) do
    try do
      final =
        Enum.reduce(remaining_binds, bindings, fn bind, acc ->
          case bind.mode do
            :pick ->
              acc

            mode ->
              effective = effective_mode(mode, :live)
              materialise(bind, acc, effective, opts)
          end
        end)

      {:ok, final}
    rescue
      e -> {:error, {:setup_failed, Exception.message(e)}}
    end
  end

  @doc """
  Translate a `:pick` mode into what the runner should actually do.
  """
  def effective_mode(:create, _), do: :create
  def effective_mode(:find, _), do: :find
  def effective_mode(:find_or_create, _), do: :find_or_create
  def effective_mode(:pick, :sandbox), do: :create
  def effective_mode(:pick, :live), do: :pick

  defp materialise(%Bind{name: name, type: type, where: where}, bindings, mode, opts) do
    resolved_where = resolve_where(where, bindings)

    entity =
      case mode do
        :create ->
          create_entity(type, resolved_where, opts)

        :find ->
          case find_entity(type, resolved_where, opts) do
            nil -> raise "Required precondition entity #{type} not found (mode: :find)"
            existing -> existing
          end

        :find_or_create ->
          find_entity(type, resolved_where, opts) || create_entity(type, resolved_where, opts)
      end

    Map.put(bindings, name, entity)
  end

  ## Picker entry points (live mode)

  @doc """
  List candidate entities for a `:pick` Bind, given the bindings the
  operator has accumulated so far.
  """
  def candidates_for(%Bind{type: type, where: where}, bindings, opts \\ []) do
    app = App.resolve(opts)
    resolved_where = resolve_where(where, bindings)

    schema = app.schema_for(type)
    limit = Keyword.get(opts, :limit, 25)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search, nil)
    preloads = app.preloads_for(type)

    base =
      from(x in schema,
        order_by: [desc: x.inserted_at],
        limit: ^limit,
        offset: ^offset
      )

    base =
      if map_size(resolved_where) == 0 do
        base
      else
        terms = Map.to_list(map_to_query_terms(resolved_where, app))
        from(x in base, where: ^terms)
      end

    base = app.apply_search(base, type, search)

    base
    |> app.repo().all()
    |> then(fn rows ->
      if preloads == [], do: rows, else: app.repo().preload(rows, preloads)
    end)
  end

  @doc "Total count of candidates matching `bind.where`."
  def candidates_count(%Bind{type: type, where: where}, bindings, opts \\ []) do
    app = App.resolve(opts)
    resolved_where = resolve_where(where, bindings)
    schema = app.schema_for(type)
    search = Keyword.get(opts, :search, nil)

    base = from(x in schema)

    base =
      if map_size(resolved_where) == 0 do
        base
      else
        terms = Map.to_list(map_to_query_terms(resolved_where, app))
        from(x in base, where: ^terms)
      end

    base = app.apply_search(base, type, search)
    app.repo().aggregate(base, :count)
  end

  @doc "Persist the operator's choice for a single pick into the bindings map."
  def resolve_pick(%Bind{name: name}, %_{} = entity, bindings) do
    Map.put(bindings, name, entity)
  end

  @doc """
  Render a one-liner label for the picker UI given an entity and its
  type. Delegates to the configured adapter.
  """
  def label_for(type, entity, opts \\ []) do
    App.resolve(opts).label_for(type, entity)
  end

  ## Act

  def act(%Action{} = action, bindings, opts \\ []) do
    actor = if action.actor, do: resolve(action.actor, bindings), else: nil
    resolved_inputs = resolve_inputs(action.inputs, bindings)
    actions_module = App.resolve(opts).actions_module()
    actions_module.run(action.name, actor, resolved_inputs, bindings)
  end

  defp resolve_inputs(inputs, bindings) when is_map(inputs) do
    Map.new(inputs, fn {k, v} -> {k, resolve(v, bindings)} end)
  end

  defp resolve_inputs(inputs, _bindings), do: inputs

  ## Verify

  def verify(postconditions, bindings, ctx \\ nil, opts \\ [])
      when is_list(postconditions) do
    {results, _bindings} =
      Enum.reduce(postconditions, {[], bindings}, fn pred, {acc, b} ->
        case evaluate(pred, b, ctx, opts) do
          {:ok, b2} -> {[{pred, :ok} | acc], b2}
          {:fail, reason} -> {[{pred, {:fail, reason}} | acc], b}
        end
      end)

    Enum.reverse(results)
  end

  ## Predicate evaluation

  def evaluate(predicate, bindings, ctx \\ nil, opts \\ [])

  def evaluate(%Exists{type: type, where: where, bind: bind, since: since}, bindings, ctx, opts) do
    resolved = resolve_where(where, bindings)
    effective_since = RunContext.effective_since(since, ctx)

    case find_entity(type, resolved, [{:since, effective_since} | opts]) do
      nil ->
        {:fail, "no #{type} matched #{inspect(resolved)}#{since_suffix(effective_since)}"}

      entity ->
        bindings = if bind, do: Map.put(bindings, bind, entity), else: bindings
        {:ok, bindings}
    end
  end

  def evaluate(%Count{type: type, op: op, n: n, where: where, since: since}, bindings, ctx, opts) do
    resolved = resolve_where(where, bindings)
    effective_since = RunContext.effective_since(since, ctx)
    actual = count_entities(type, resolved, [{:since, effective_since} | opts])

    if compare(actual, op, n) do
      {:ok, bindings}
    else
      {:fail,
       "count(#{type}, #{inspect(resolved)}#{since_suffix(effective_since)}) = #{actual}, expected #{op} #{n}"}
    end
  end

  def evaluate(%Attribute{ref: ref, key: key, op: op, value: value}, bindings, _ctx, opts) do
    entity = resolve(ref, bindings) |> reload(opts)
    actual = Map.get(entity, key)

    if attribute_matches?(actual, op, value) do
      {:ok, bindings}
    else
      {:fail, "#{ref.name}.#{key} = #{inspect(actual)}, expected #{op} #{inspect(value)}"}
    end
  end

  def evaluate(%Relationship{from: from, assoc: assoc, to: to}, bindings, _ctx, opts) do
    from_entity = resolve(from, bindings) |> reload(opts)
    to_entity = resolve(to, bindings)
    fk_field = String.to_atom("#{assoc}_id")

    if Map.get(from_entity, fk_field) == to_entity.id do
      {:ok, bindings}
    else
      {:fail, "#{from.name}.#{fk_field} != #{to.name}.id"}
    end
  end

  def evaluate(%MessageSent{type: type, to: to, about: about, since: since}, bindings, ctx, opts) do
    app = App.resolve(opts)
    notif = app.notification()

    if is_nil(notif) do
      {:fail, "host app does not implement a notification model"}
    else
      to_user = resolve(to, bindings)
      about_entity = if about, do: resolve(about, bindings), else: nil
      effective_since = RunContext.effective_since(since, ctx)

      query =
        from(n in notif.schema,
          where:
            field(n, ^notif.type_field) == ^type and
              field(n, ^notif.recipient_field) == ^to_user.id
        )

      query =
        case about_entity do
          nil -> query
          entity -> from n in query, where: field(n, ^notif.subject_field) == ^entity.id
        end

      query =
        case effective_since do
          nil ->
            query

          ts ->
            from n in query, where: field(n, ^notif.inserted_at_field) >= ^to_naive(ts)
        end

      case app.repo().aggregate(query, :count) do
        0 ->
          {:fail, "no #{type} notification sent to #{to.name}#{since_suffix(effective_since)}"}

        _ ->
          {:ok, bindings}
      end
    end
  end

  def evaluate(%None{type: type, where: where, since: since}, bindings, ctx, opts) do
    resolved = resolve_where(where, bindings)
    effective_since = RunContext.effective_since(since, ctx)
    n = count_entities(type, resolved, [{:since, effective_since} | opts])

    if n == 0 do
      {:ok, bindings}
    else
      {:fail,
       "expected zero #{type} matching #{inspect(resolved)}#{since_suffix(effective_since)}, found #{n}"}
    end
  end

  def evaluate(%ForAll{type: type, where: where, assert: asserts, bind_as: bind_as}, bindings, ctx, opts) do
    resolved = resolve_where(where, bindings)
    entities = list_entities(type, resolved, opts)

    failures =
      entities
      |> Enum.flat_map(fn entity ->
        scoped = Map.put(bindings, bind_as, entity)

        Enum.flat_map(asserts, fn pred ->
          case evaluate(pred, scoped, ctx, opts) do
            {:ok, _} -> []
            {:fail, reason} -> [{entity.id, reason}]
          end
        end)
      end)

    if failures == [] do
      {:ok, bindings}
    else
      {:fail, "#{length(failures)} of #{length(entities)} #{type}s failed: #{inspect(Enum.take(failures, 3))}"}
    end
  end

  defp since_suffix(nil), do: ""
  defp since_suffix(ts), do: " (since #{DateTime.to_iso8601(ts)})"

  ## Invariants — delegate to the configured adapter

  defp check_invariants(%Scenario{invariants: :none}, _bindings, _ctx, _opts), do: []

  defp check_invariants(%Scenario{invariants: invariants}, bindings, ctx, opts)
       when is_list(invariants) do
    Enum.flat_map(invariants, &Np.Invariants.check(&1, bindings, ctx, opts))
  end

  defp check_invariants(%Scenario{invariants: :standard}, bindings, ctx, opts) do
    Np.Invariants.check_standard(bindings, ctx, opts)
  end

  ## Entity helpers — adapter-driven

  defp find_entity(type, where, opts) do
    app = App.resolve(opts)
    schema = app.schema_for(type)
    since = Keyword.get(opts, :since)

    base = from(x in schema, limit: 1)

    base =
      if map_size(where) == 0 do
        base
      else
        from x in base, where: ^Map.to_list(map_to_query_terms(where, app))
      end

    base =
      case since do
        nil -> base
        ts -> from x in base, where: x.inserted_at >= ^to_naive(ts)
      end

    base |> app.repo().all() |> List.first()
  end

  defp list_entities(type, where, opts) do
    app = App.resolve(opts)
    schema = app.schema_for(type)

    if map_size(where) == 0 do
      app.repo().all(schema)
    else
      app.repo().all(from(x in schema, where: ^Map.to_list(map_to_query_terms(where, app))))
    end
  end

  defp count_entities(type, where, opts) do
    app = App.resolve(opts)
    schema = app.schema_for(type)
    since = Keyword.get(opts, :since)

    base = from(x in schema)

    base =
      if map_size(where) == 0 do
        base
      else
        from x in base, where: ^Map.to_list(map_to_query_terms(where, app))
      end

    base =
      case since do
        nil -> base
        ts -> from x in base, where: x.inserted_at >= ^to_naive(ts)
      end

    app.repo().aggregate(base, :count)
  end

  defp to_naive(%DateTime{} = dt), do: DateTime.to_naive(dt)
  defp to_naive(%NaiveDateTime{} = nd), do: nd

  defp create_entity(type, where, opts) do
    App.resolve(opts).build_entity(type, where)
  end

  defp map_to_query_terms(where, app) do
    Enum.into(where, %{}, fn
      {key, %{__struct__: _} = struct} -> {app.fk_for(key), struct.id}
      {key, value} -> {key, value}
    end)
  end

  ## Ref resolution

  defp resolve_where(where, bindings) when is_map(where) do
    Map.new(where, fn {k, v} -> {k, resolve(v, bindings)} end)
  end

  defp resolve(%Ref{name: name}, bindings) do
    Map.get(bindings, name) ||
      raise "unbound ref :#{name} — bindings: #{inspect(Map.keys(bindings))}"
  end

  defp resolve(other, _bindings), do: other

  defp reload(%{__struct__: schema, id: id}, opts),
    do: App.resolve(opts).repo().get!(schema, id)

  ## Comparisons

  defp compare(a, :==, b), do: a == b
  defp compare(a, :!=, b), do: a != b
  defp compare(a, :>, b), do: a > b
  defp compare(a, :>=, b), do: a >= b
  defp compare(a, :<, b), do: a < b
  defp compare(a, :<=, b), do: a <= b

  defp attribute_matches?(actual, :is_set, _), do: not is_nil(actual)
  defp attribute_matches?(actual, :is_nil, _), do: is_nil(actual)
  defp attribute_matches?(actual, op, value), do: compare(actual, op, value)

  ## Result aggregation

  defp all_ok?(results) do
    Enum.all?(results, fn
      {_pred, :ok} -> true
      _ -> false
    end)
  end
end
