# Changelog

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
