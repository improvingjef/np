if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Np.LiveView do
    @moduledoc """
    User Acceptance harness LiveView — drives a `Np.Scenario` through
    setup, prompted-action, and verify phases with a human in the
    loop.

    Phase machine:

        pick_runner → pick_scenario → picking* → act → done

    (`picking` is skipped entirely in sandbox mode; `act` shows the
    UAT prompt with two buttons — "I did it — verify" or "Do it for
    me — verify" — the latter dispatches the registered action
    handler so non-technical operators can watch the system work
    before doing it.)

    ## Mounting

    Mount on any route in the host app:

        live "/uat", Np.LiveView, :index

    The host configures the scenario catalog:

        config :np,
          app: MyApp.Acceptance,
          scenarios: %{
            "M5-assign-translation" =>
              MyApp.Acceptance.Scenarios.M5AssignTranslation,
            "M8-dry-run" => MyApp.Acceptance.Scenarios.M8DryRun
          }

    Reload-from-DB:

        /uat?run=<run-id>

    loads a persisted run and jumps straight to `:done`.
    """
    use Phoenix.LiveView, layout: false

    alias Np.{Interpreter, RunContext}

    @page_size 25

    @impl true
    def mount(params, _session, socket) do
      socket =
        socket
        |> assign(:page_title, "User Acceptance Harness")
        |> assign(:page_size, @page_size)
        |> assign(:scenarios, scenarios())
        |> reset_state()

      case params do
        %{"run" => id} when is_binary(id) -> {:ok, load_persisted_run(socket, id)}
        _ -> {:ok, socket}
      end
    end

    defp scenarios do
      Application.get_env(:np, :scenarios, %{})
    end

    defp load_persisted_run(socket, id) do
      case Np.get_run(id) do
        nil ->
          put_flash(socket, :error, "Run #{id} not found.")

        run ->
          socket
          |> assign(:phase, :done)
          |> assign(:acceptance_run, run)
          |> assign(:scenario, scenario_for(run.scenario_id))
          |> assign(:runner, run.runner)
      end
    end

    defp scenario_for(scenario_id) do
      case Map.get(scenarios(), scenario_id) do
        nil -> %{id: scenario_id, title: scenario_id, narrative: ""}
        module -> module.scenario()
      end
    end

    defp reset_state(socket) do
      socket
      |> assign(:phase, :pick_runner)
      |> assign(:runner, nil)
      |> assign(:scenario, nil)
      |> assign(:bindings, %{})
      |> assign(:remaining_picks, [])
      |> assign(:current_pick, nil)
      |> assign(:pick_history, [])
      |> assign(:candidates, [])
      |> assign(:candidate_total, 0)
      |> assign(:search, "")
      |> assign(:offset, 0)
      |> assign(:prompt, nil)
      |> assign(:result, nil)
      |> assign(:run_context, nil)
      |> assign(:acceptance_run, nil)
    end

    ## Event handlers

    @impl true
    def handle_event("pick_runner", %{"runner" => runner}, socket)
        when runner in ["sandbox", "live"] do
      {:noreply,
       socket
       |> assign(:runner, String.to_existing_atom(runner))
       |> assign(:phase, :pick_scenario)}
    end

    def handle_event("pick_scenario", %{"id" => id}, socket) do
      module = Map.fetch!(socket.assigns.scenarios, id)
      scenario = module.scenario()
      runner = socket.assigns.runner

      case Interpreter.setup(scenario.preconditions, runner: runner) do
        {:ok, bindings} ->
          advance_to_act(socket, scenario, bindings)

        {:picks_required, bindings, picks} ->
          [first | rest] = picks

          socket
          |> assign(:scenario, scenario)
          |> assign(:bindings, bindings)
          |> assign(:remaining_picks, rest)
          |> assign(:current_pick, first)
          |> assign(:pick_history, [])
          |> assign(:phase, :picking)
          |> load_candidates_for_current_pick()
          |> noreply()

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Setup failed: #{inspect(reason)}")
           |> assign(:phase, :pick_scenario)}
      end
    end

    def handle_event("search", %{"q" => q}, socket) do
      socket
      |> assign(:search, q)
      |> assign(:offset, 0)
      |> load_candidates_for_current_pick()
      |> noreply()
    end

    def handle_event("load_more", _params, socket) do
      socket
      |> assign(:offset, socket.assigns.offset + @page_size)
      |> load_candidates_for_current_pick(:append)
      |> noreply()
    end

    def handle_event("select_candidate", %{"id" => entity_id}, socket) do
      entity = Enum.find(socket.assigns.candidates, fn e -> e.id == entity_id end)

      if entity do
        bindings =
          Interpreter.resolve_pick(socket.assigns.current_pick, entity, socket.assigns.bindings)

        history_entry = %{
          bind: socket.assigns.current_pick,
          choice: entity,
          search: socket.assigns.search
        }

        pick_history = [history_entry | socket.assigns.pick_history]

        case socket.assigns.remaining_picks do
          [] ->
            case Interpreter.resume_setup([], bindings) do
              {:ok, finalised} ->
                advance_to_act(socket, socket.assigns.scenario, finalised)

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, "Setup failed: #{inspect(reason)}")}
            end

          [next | rest] ->
            socket
            |> assign(:bindings, bindings)
            |> assign(:current_pick, next)
            |> assign(:remaining_picks, rest)
            |> assign(:pick_history, pick_history)
            |> assign(:search, "")
            |> assign(:offset, 0)
            |> load_candidates_for_current_pick()
            |> noreply()
        end
      else
        {:noreply, put_flash(socket, :error, "Couldn't find that selection — try refreshing.")}
      end
    end

    def handle_event("back", _params, socket) do
      case socket.assigns.pick_history do
        [] ->
          {:noreply, socket}

        [last | rest] ->
          bindings = Map.delete(socket.assigns.bindings, last.bind.name)
          new_remaining = [socket.assigns.current_pick | socket.assigns.remaining_picks]

          socket
          |> assign(:bindings, bindings)
          |> assign(:current_pick, last.bind)
          |> assign(:remaining_picks, new_remaining)
          |> assign(:pick_history, rest)
          |> assign(:search, last.search || "")
          |> assign(:offset, 0)
          |> load_candidates_for_current_pick()
          |> noreply()
      end
    end

    def handle_event("verify_after_user_act", _params, socket) do
      {:ok, result} =
        Interpreter.finish(socket.assigns.scenario, socket.assigns.bindings,
          run_context: socket.assigns.run_context
        )

      {:ok, run} = Np.finish_run(socket.assigns.acceptance_run, result)

      {:noreply,
       socket
       |> assign(:result, result)
       |> assign(:acceptance_run, run)
       |> assign(:phase, :done)}
    end

    def handle_event("auto_act_then_verify", _params, socket) do
      case Interpreter.act(socket.assigns.scenario.action, socket.assigns.bindings) do
        {:ok, action_bindings} ->
          merged = Map.merge(socket.assigns.bindings, action_bindings)

          {:ok, result} =
            Interpreter.finish(socket.assigns.scenario, merged,
              run_context: socket.assigns.run_context
            )

          {:ok, run} = Np.finish_run(socket.assigns.acceptance_run, result)

          {:noreply,
           socket
           |> assign(:bindings, merged)
           |> assign(:result, result)
           |> assign(:acceptance_run, run)
           |> assign(:phase, :done)}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Action failed: #{inspect(reason)}")
           |> assign(:phase, :act)}
      end
    end

    def handle_event("restart", _params, socket) do
      {:noreply, reset_state(socket)}
    end

    ## Internals

    defp advance_to_act(socket, scenario, bindings) do
      ctx = RunContext.new(runner: socket.assigns.runner)
      operator_id = current_operator_id(socket)
      {:ok, run} = Np.start_run(scenario.id, ctx.runner, ctx, bindings, operator_id)

      case Interpreter.prompt_for(scenario, bindings) do
        {:ok, prompt} ->
          {:noreply,
           socket
           |> assign(:scenario, scenario)
           |> assign(:bindings, bindings)
           |> assign(:run_context, ctx)
           |> assign(:acceptance_run, run)
           |> assign(:prompt, prompt)
           |> assign(:phase, :act)}

        {:error, :no_prompt} ->
          case Interpreter.act(scenario.action, bindings) do
            {:ok, action_bindings} ->
              merged = Map.merge(bindings, action_bindings)
              {:ok, result} = Interpreter.finish(scenario, merged, run_context: ctx)
              {:ok, run} = Np.finish_run(run, result)

              {:noreply,
               socket
               |> assign(:scenario, scenario)
               |> assign(:bindings, merged)
               |> assign(:run_context, ctx)
               |> assign(:acceptance_run, run)
               |> assign(:result, result)
               |> assign(:phase, :done)
               |> put_flash(:info, "No UAT prompt — auto-ran the action handler.")}

            {:error, reason} ->
              {:noreply,
               socket
               |> put_flash(:error, "Action failed: #{inspect(reason)}")
               |> assign(:phase, :pick_scenario)}
          end
      end
    end

    defp current_operator_id(socket) do
      case socket.assigns[:current_user] do
        %{id: id} -> id
        _ -> nil
      end
    end

    defp load_candidates_for_current_pick(socket, mode \\ :replace) do
      bind = socket.assigns.current_pick
      search = socket.assigns.search
      offset = socket.assigns.offset

      candidates =
        Interpreter.candidates_for(bind, socket.assigns.bindings,
          search: search,
          limit: @page_size,
          offset: offset
        )

      candidates =
        case mode do
          :replace -> candidates
          :append -> socket.assigns.candidates ++ candidates
        end

      total = Interpreter.candidates_count(bind, socket.assigns.bindings, search: search)

      socket
      |> assign(:candidates, candidates)
      |> assign(:candidate_total, total)
    end

    defp noreply(socket), do: {:noreply, socket}

    ## Render — minimal styling, host can override via CSS

    @impl true
    def render(assigns) do
      ~H"""
      <div class="np-uat" data-testid="np-uat">
        <h1>User Acceptance Harness</h1>
        <p class="np-uat-intro">
          Pick a runner, pick a scenario, perform the action in another window, mark it accepted or rejected.
        </p>

        <%= case @phase do %>
          <% :pick_runner -> %>
            <.runner_phase />
          <% :pick_scenario -> %>
            <.scenario_phase scenarios={@scenarios} runner={@runner} />
          <% :picking -> %>
            <.picking_phase
              current_pick={@current_pick}
              remaining_picks={@remaining_picks}
              pick_history={@pick_history}
              candidates={@candidates}
              candidate_total={@candidate_total}
              search={@search}
              page_size={@page_size}
            />
          <% :act -> %>
            <.act_phase scenario={@scenario} bindings={@bindings} prompt={@prompt} />
          <% :done -> %>
            <.done_phase scenario={@scenario} run={@acceptance_run} />
        <% end %>
      </div>
      """
    end

    defp runner_phase(assigns) do
      ~H"""
      <section class="np-card" data-testid="uat-pick-runner">
        <h2>Pick a runner</h2>
        <button phx-click="pick_runner" phx-value-runner="sandbox" data-testid="uat-runner-sandbox">
          Sandbox — factory-build every entity
        </button>
        <button phx-click="pick_runner" phx-value-runner="live" data-testid="uat-runner-live">
          Live — pick existing entities (real consequences)
        </button>
      </section>
      """
    end

    attr :scenarios, :map, required: true
    attr :runner, :atom, required: true

    defp scenario_phase(assigns) do
      ~H"""
      <section class="np-card" data-testid="uat-pick">
        <h2>Pick a scenario · <span class="np-runner-badge">{@runner}</span></h2>
        <%= for {id, _module} <- @scenarios do %>
          <button phx-click="pick_scenario" phx-value-id={id} data-testid={"uat-pick-#{id}"}>
            {id}
          </button>
        <% end %>
      </section>
      """
    end

    attr :current_pick, :map, required: true
    attr :remaining_picks, :list, required: true
    attr :pick_history, :list, required: true
    attr :candidates, :list, required: true
    attr :candidate_total, :integer, required: true
    attr :search, :string, required: true
    attr :page_size, :integer, required: true

    defp picking_phase(assigns) do
      step = length(assigns.pick_history) + 1
      total = step + length(assigns.remaining_picks)
      assigns = assign(assigns, step: step, total: total)

      ~H"""
      <section class="np-card" data-testid="uat-picking">
        <header>
          <small>Step <span data-testid="uat-pick-step">{@step}</span> of {@total}</small>
          <h2>{@current_pick.label || "Pick a #{@current_pick.type}"}</h2>
          <%= if @pick_history != [] do %>
            <button phx-click="back" data-testid="uat-back">← Back</button>
          <% end %>
        </header>

        <%= if @pick_history != [] do %>
          <ul class="np-pick-trail" data-testid="uat-pick-trail">
            <%= for entry <- Enum.reverse(@pick_history) do %>
              <li>
                <code>{entry.bind.name}:</code>
                {Interpreter.label_for(entry.bind.type, entry.choice)}
              </li>
            <% end %>
          </ul>
        <% end %>

        <form phx-change="search" phx-submit="search">
          <input
            type="text"
            name="q"
            value={@search}
            placeholder={"Search #{@current_pick.type}…"}
            data-testid="uat-pick-search"
            phx-debounce="200"
          />
        </form>

        <%= if @candidates == [] do %>
          <p class="np-empty" data-testid="uat-pick-empty">
            No <%= @current_pick.type %> matches your filters.
            <%= if @pick_history != [] do %>Try Back to widen the criteria.<% end %>
          </p>
        <% else %>
          <ul class="np-candidates" data-testid="uat-candidates">
            <%= for entity <- @candidates do %>
              <li>
                <button
                  phx-click="select_candidate"
                  phx-value-id={entity.id}
                  data-testid={"uat-candidate-#{entity.id}"}
                >
                  {Interpreter.label_for(@current_pick.type, entity)}
                </button>
              </li>
            <% end %>
          </ul>

          <%= if length(@candidates) < @candidate_total do %>
            <button phx-click="load_more" data-testid="uat-load-more">
              Load more ({length(@candidates)} of {@candidate_total} shown)
            </button>
          <% end %>
        <% end %>
      </section>
      """
    end

    attr :scenario, :map, required: true
    attr :bindings, :map, required: true
    attr :prompt, :map, required: true

    defp act_phase(assigns) do
      ~H"""
      <section class="np-card" data-testid="uat-act">
        <header>
          <small>Scenario</small>
          <h2>{@scenario.title}</h2>
          <p class="np-narrative">{@scenario.narrative}</p>
        </header>

        <details>
          <summary>World ({map_size(@bindings)} entities)</summary>
          <ul class="np-bindings">
            <%= for {name, entity} <- @bindings do %>
              <li>
                <code>:{name}</code> → {entity.__struct__ |> Module.split() |> List.last()}
              </li>
            <% end %>
          </ul>
        </details>

        <div class="np-prompt">
          <h3>{@prompt.title}</h3>
          <div class="np-prompt-body">{@prompt.body}</div>

          <%= if @prompt[:goto] do %>
            <a href={@prompt.goto} target="_blank" data-testid="uat-goto">
              Open <code>{@prompt.goto}</code> in a new tab ↗
            </a>
          <% end %>
        </div>

        <footer class="np-actions">
          <button phx-click="auto_act_then_verify" data-testid="uat-auto-act">
            Do it for me — verify
          </button>
          <button phx-click="verify_after_user_act" data-testid="uat-user-act">
            I did it — verify
          </button>
        </footer>
      </section>
      """
    end

    attr :scenario, :map, required: true
    attr :run, :map, required: true

    defp done_phase(assigns) do
      passed? = assigns.run.status == :passed
      assigns = assign(assigns, passed?: passed?)

      ~H"""
      <div class="np-done" data-testid="uat-done">
        <section class={"np-card np-verdict #{if @passed?, do: "np-passed", else: "np-failed"}"}>
          <header>
            <%= if @passed? do %>
              <h2>✓ Accepted</h2>
              <p>All postconditions and invariants passed.</p>
            <% else %>
              <h2>✗ Rejected</h2>
              <p>At least one check failed below.</p>
            <% end %>
            <aside class="np-run-meta" data-testid="uat-run-meta">
              <div>{@run.scenario_id}</div>
              <div>{@run.runner} · {@run.started_at && Calendar.strftime(@run.started_at, "%Y-%m-%d %H:%M")}</div>
              <div>id: <a href={"?run=" <> @run.id}>{String.slice(@run.id, 0, 8)}</a></div>
            </aside>
          </header>
        </section>

        <section class="np-card">
          <h3>Postconditions</h3>
          <ul data-testid="uat-postconditions">
            <%= for entry <- @run.postcondition_results do %>
              <.result_row label={entry["predicate"]} status={entry["status"]} reason={entry["reason"]} />
            <% end %>
          </ul>
        </section>

        <section class="np-card">
          <h3>Invariants</h3>
          <ul data-testid="uat-invariants">
            <%= for entry <- @run.invariant_results do %>
              <.result_row label={entry["name"]} status={entry["status"]} reason={entry["reason"]} />
            <% end %>
          </ul>
        </section>

        <button phx-click="restart" data-testid="uat-restart">Run another scenario</button>
      </div>
      """
    end

    attr :label, :string, required: true
    attr :status, :string, required: true
    attr :reason, :string, default: nil

    defp result_row(assigns) do
      ~H"""
      <li class={"np-result #{if @status == "ok", do: "np-ok", else: "np-fail"}"}>
        <%= if @status == "ok" do %>
          <span class="np-icon">✓</span>
          <span>{@label}</span>
        <% else %>
          <span class="np-icon">✗</span>
          <div>
            <div>{@label}</div>
            <%= if @reason do %>
              <small><code>{@reason}</code></small>
            <% end %>
          </div>
        <% end %>
      </li>
      """
    end
  end
end
