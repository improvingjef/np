defmodule Np.RunContext do
  @moduledoc """
  Per-run metadata threaded through `verify/3` and predicate
  evaluators.

  Carries information that's known at the start of the run but
  needed by predicates that count or list entities — most importantly
  `started_at`, which postcondition predicates use as the default
  `since:` filter so live UAT doesn't false-positive against entities
  created before the run.
  """

  defstruct [
    :run_id,
    :started_at,
    :runner,
    :operator_id
  ]

  @type t :: %__MODULE__{
          run_id: binary() | nil,
          started_at: DateTime.t() | nil,
          runner: :sandbox | :live | nil,
          operator_id: binary() | nil
        }

  @doc """
  Build a fresh context. `started_at` defaults to now; `runner`
  defaults to `:sandbox`.
  """
  def new(opts \\ []) do
    %__MODULE__{
      run_id: Keyword.get(opts, :run_id),
      started_at:
        Keyword.get(opts, :started_at, DateTime.utc_now() |> DateTime.truncate(:microsecond)),
      runner: Keyword.get(opts, :runner, :sandbox),
      operator_id: Keyword.get(opts, :operator_id)
    }
  end

  @doc """
  Resolve the effective `since` filter for a predicate, given:

    * the predicate's own `since` (if explicitly set), or
    * the run context's `started_at` (when the runner is `:live`), or
    * `nil` (sandbox runs don't filter — the world is fresh)
  """
  def effective_since(predicate_since, %__MODULE__{} = ctx) do
    cond do
      not is_nil(predicate_since) -> predicate_since
      ctx.runner == :live -> ctx.started_at
      true -> nil
    end
  end

  def effective_since(predicate_since, _no_ctx), do: predicate_since
end
