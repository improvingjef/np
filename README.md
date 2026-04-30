# np

**No problem. Acceptance testing for humans.**

A small DSL for writing acceptance scenarios as data, plus three runners that share the same scenario file:

- **Test runner** — ExUnit calls `Np.run/2`. Preconditions get factory-built, the action handler runs, postconditions are verified. Cheap, fast, runs on every commit.
- **UAT runner** — a LiveView walks an operator through a scenario in two modes: *sandbox* (factory-build everything; safe for dev demos / dogfood) or *live* (operator picks real entities through searchable, paginated dropdowns; for UAT against staged production data).
- **Live drift** — the same predicates run against the live database with no scenario context. Failures are spec drift.

The scenario itself is data. The same predicate vocabulary covers all three.

## Status

Pre-1.0. The constraint vocabulary is closed and the runners work, but expect cosmetic API changes. The two-letter package name is on purpose — it earns it.

## Installation

```elixir
def deps do
  [
    {:np, "~> 0.1"}
  ]
end
```

## Quickstart

### 1. Configure

```elixir
# config/config.exs
config :np,
  app: MyApp.Acceptance,
  scenarios: %{
    "M5-assign-translation" => MyApp.Acceptance.Scenarios.M5AssignTranslation
  }
```

### 2. Implement the adapter

The framework is domain-agnostic. Your adapter wires it to your schemas, factories, search columns, and notification model.

```elixir
defmodule MyApp.Acceptance do
  @behaviour Np.App

  @impl true
  def repo, do: MyApp.Repo

  @impl true
  def schema_for(:user), do: MyApp.Accounts.User
  def schema_for(:order), do: MyApp.Sales.Order

  @impl true
  def build_entity(type, where), do: MyApp.Factory.insert(type, Map.to_list(where))

  @impl true
  def fk_for(:user), do: :user_id
  def fk_for(other), do: String.to_atom(Atom.to_string(other) <> "_id")

  @impl true
  def apply_search(query, :user, search) when is_binary(search) do
    import Ecto.Query
    from u in query, where: ilike(u.email, ^"%#{search}%")
  end
  def apply_search(query, _type, _), do: query

  @impl true
  def preloads_for(_), do: []

  @impl true
  def label_for(:user, %{email: e}), do: e
  def label_for(_, %{id: id}), do: "##{String.slice(id, 0, 8)}"

  @impl true
  def notification, do: nil   # or %{schema: ..., type_field: ..., ...}

  @impl true
  def actions_module, do: MyApp.Acceptance.Actions

  @impl true
  def invariants_module, do: MyApp.Acceptance.Invariants
end
```

### 3. Action handlers

```elixir
defmodule MyApp.Acceptance.Actions do
  @behaviour Np.Actions

  @impl true
  def run(:place_order, actor, %{cart: cart}, _bindings) do
    case MyApp.Sales.place_order(actor, cart) do
      {:ok, order} -> {:ok, %{placed_order: order}}
      {:error, e} -> {:error, e}
    end
  end

  def run(name, _, _, _), do: {:error, {:unknown_action, name}}
end
```

### 4. Invariants

```elixir
defmodule MyApp.Acceptance.Invariants do
  @behaviour Np.Invariants
  alias Np.Predicate

  @impl true
  def standard do
    %{
      "every order has a customer_id" => [
        %Predicate.ForAll{
          type: :order,
          assert: [Predicate.attribute(:it, :customer_id, :is_set)]
        }
      ]
    }
  end
end
```

### 5. Write a scenario

```elixir
defmodule MyApp.Acceptance.Scenarios.PlaceOrder do
  alias Np.{Action, Predicate, Ref, Scenario}

  def scenario do
    %Scenario{
      id: "place-order",
      title: "Customer places an order",
      preconditions: [
        Predicate.pick(:customer, :user, %{}, "Pick the customer"),
        Predicate.pick(:cart, :cart, %{user: Ref.new(:customer)}, "Pick a cart")
      ],
      action: %Action{
        name: :place_order,
        actor: Ref.new(:customer),
        inputs: %{cart: Ref.new(:cart)},
        prompt: fn b -> %{
          title: "Place the order for #{b.customer.email}",
          body: "1. Sign in as #{b.customer.email}\n2. Open the cart\n3. Click Place Order\n4. Come back and click I did it.",
          goto: "/carts/#{b.cart.id}"
        } end
      },
      postconditions: [
        Predicate.relationship(:placed_order, :customer, :customer),
        Predicate.attribute(:placed_order, :status, :==, "placed")
      ]
    }
  end
end
```

### 6. Migrate

```bash
mix np.gen.migration
mix ecto.migrate
```

### 7. Mount the LiveView

```elixir
# lib/my_app_web/router.ex
scope "/", MyAppWeb do
  pipe_through [:browser, :require_admin]

  live "/uat", Np.LiveView, :index
end
```

### 8. Run the same scenario from ExUnit

```elixir
test "place_order: customer places, status moves to placed" do
  {:ok, result} = Np.run(MyApp.Acceptance.Scenarios.PlaceOrder.scenario())
  assert result.passed?
end
```

### 9. (optional) Drive the same scenario through Playwright

The third runner spawns a real browser. Same scenario file, same predicates — the only host work is the click-through script.

```bash
npm install -D @playwright/test
npx playwright install
```

Test file (host-side):

```js
// playwright/place_order.spec.js
import { test, expect } from '@playwright/test';
import { loadFixture, scenarioId } from '../deps/np/priv/js/np.fixture.js';

test('place-order', async ({ page }) => {
  if (scenarioId() !== 'place-order') test.skip();
  const f = loadFixture();

  await page.goto('/login');
  await page.fill('[name=email]', f.bindings.customer.display.email);
  await page.fill('[name=password]', 'password123456');
  await page.click('button[type=submit]');

  await page.goto(f.prompt.goto);
  await page.click('[data-testid=place-order]');
  await expect(page.locator('[data-testid=order-placed]')).toBeVisible();
});
```

Run it:

```bash
mix np.playwright place-order
```

The Mix task sets up preconditions in `:sandbox`, persists a `:running` row, writes a JSON fixture, spawns `npx playwright test --grep place-order` with `NP_FIXTURE_PATH` / `NP_RUN_ID` / `NP_SCENARIO_ID` env vars, then verifies postconditions in-memory after Playwright exits. Exit codes: `0` accepted, `1` Playwright-passed-but-rejected, `2+` Playwright errored.

## The constraint vocabulary

Predicates are a closed set. Add a new one only when the workaround is unbearable.

- `Bind` — precondition; bind an entity by name. Modes: `:create`, `:find`, `:find_or_create`, `:pick`.
- `Exists` — at least one entity matches `where`.
- `None` — zero entities match.
- `Count` — count satisfies `op n`.
- `Attribute` — a named attribute on a bound entity satisfies `op value`.
- `Relationship` — bound entity has the named association to another bound entity.
- `MessageSent` — a notification was sent (delegates to the host's notification schema).
- `ForAll` — for every matching entity, an assertion list holds. The vehicle for invariants.

In `:live` mode, `Count`/`Exists`/`MessageSent`/`None` automatically scope to `started_at` so postconditions don't false-positive on history.

## License

MIT.
