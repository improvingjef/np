# Changelog

## 0.1.2

- `Interpreter.setup/2` accepts a `:seed_bindings` map that pre-
  populates the bindings before the precondition list runs. `Bind`
  elements whose name is already in the seed are skipped — they're
  considered "already materialised by the host". This is how a host
  app grafts the operator's identity onto a sandbox run (e.g. the
  `:tenant` and `:team_leader` bindings become the operator's own
  tenant + the operator themselves) so the resulting state is visible
  to the operator's session and gated UI affordances render
  correctly.

## 0.1.1

- **Breaking** (for hosts already migrated): `Np.Run.operator_id` is
  now `:string` instead of `:binary_id`. Hosts whose user IDs aren't
  UUIDs (integers, ULIDs, opaque tokens) can finally store an
  operator id. Hosts that already created the `acceptance_runs`
  table with a `uuid` column should ALTER it to `varchar` —
  one-line migration.
- `mix np.gen.migration` now namespaces the generated migration
  module under the host's repo (e.g.
  `MyApp.Repo.Migrations.CreateAcceptanceRuns`), matching Phoenix
  convention. Previously it generated `Repo.Migrations.…` which
  collided with most hosts.
- Tests now cover the operator_id type and the migration
  generator's template (20 tests total).

## 0.1.0 — unreleased

Initial release.

- Closed predicate vocabulary: `Bind`, `Exists`, `None`, `Count`,
  `Attribute`, `Relationship`, `MessageSent`, `ForAll`.
- Three runners share the same scenario data: ExUnit (`Np.run/2`),
  UAT LiveView (`Np.LiveView`), and live drift (`Np.Invariants.live_drift/1`).
- `Np.App` adapter behaviour wires the framework to the host app's
  schemas, factories, search columns, labels, notification model,
  action handlers, and invariants.
- `Np.Actions` and `Np.Invariants` behaviours for the host's
  per-scenario imperative code and cross-cutting checks.
- Persisted run ledger (`Np.Run`) — every UAT run lands in
  `acceptance_runs`. `/uat?run=<id>` reloads the result page.
- `since:` filter on postconditions, auto-applied in `:live` mode so
  predicates don't false-positive on pre-run history.
- `mix np.gen.migration` ships the `acceptance_runs` table.
