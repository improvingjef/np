defmodule NpTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Np.{Action, Predicate, Ref, Scenario, TestRepo}

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  describe "Np.run/2 — end-to-end with the test app adapter" do
    test "creates preconditions, runs the action, verifies postconditions" do
      scenario = %Scenario{
        id: "enable-gadget",
        title: "Enable a draft gadget",
        preconditions: [
          Predicate.bind(:widget, :widget),
          Predicate.bind(:gadget, :gadget, %{widget: Ref.new(:widget)})
        ],
        action: %Action{
          name: :enable_gadget,
          inputs: %{gadget: Ref.new(:gadget)}
        },
        postconditions: [
          Predicate.attribute(:enabled_gadget, :enabled, :==, true),
          Predicate.relationship(:enabled_gadget, :widget, :widget)
        ]
      }

      assert {:ok, result} = Np.run(scenario)
      assert result.passed?
      assert Enum.all?(result.postconditions, fn {_, status} -> status == :ok end)
      assert Enum.all?(result.invariants, fn {_, status} -> status == :ok end)
    end

    test "since: filter — Count auto-scopes to started_at in :live mode" do
      ctx = Np.RunContext.new(runner: :live)

      # Pre-existing widget from before the run.
      old_ts =
        ctx.started_at
        |> DateTime.add(-3600, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      old =
        TestRepo.insert!(%Np.Test.Widget{
          name: "before-run",
          inserted_at: old_ts,
          updated_at: old_ts
        })

      pred = Predicate.count(:widget, :==, 0, %{name: "before-run"})

      # Without ctx → counts old row → fails.
      assert {:fail, _} = Np.Interpreter.evaluate(pred, %{})

      # With ctx in :live mode → since auto-applies → old row excluded → passes.
      assert {:ok, _} = Np.Interpreter.evaluate(pred, %{}, ctx)

      TestRepo.delete!(old)
    end
  end

  describe "Np.start_run / finish_run — persistence" do
    test "round-trips a run through the acceptance_runs table" do
      ctx = Np.RunContext.new(runner: :sandbox)

      {:ok, run} = Np.start_run("test-scenario", :sandbox, ctx, %{})
      assert run.status == :running
      assert run.scenario_id == "test-scenario"

      result = %{passed?: true, postconditions: [], invariants: []}
      {:ok, finished} = Np.finish_run(run, result)
      assert finished.status == :passed
      assert finished.completed_at

      assert Np.get_run(run.id).status == :passed
    end

    test "persisted result rows include serialized predicate summaries" do
      ctx = Np.RunContext.new(runner: :sandbox)
      {:ok, run} = Np.start_run("x", :sandbox, ctx, %{})

      pred = Predicate.attribute(Ref.new(:thing), :status, :==, "ok")

      result = %{
        passed?: false,
        postconditions: [{pred, {:fail, "thing.status was nil"}}],
        invariants: [{{:invariant, "always-on"}, :ok}]
      }

      {:ok, finished} = Np.finish_run(run, result)
      [%{"predicate" => label, "status" => status, "reason" => reason}] =
        finished.postcondition_results

      assert label == "thing.status == \"ok\""
      assert status == "fail"
      assert reason == "thing.status was nil"

      assert finished.invariant_results == [%{
        "name" => "always-on",
        "status" => "ok",
        "reason" => nil
      }]
    end

    test "operator_id accepts non-UUID strings (integer ids, ULIDs, opaque tokens)" do
      ctx = Np.RunContext.new(runner: :sandbox)

      # An integer id (revivehub-style) cast to string by the host.
      {:ok, run} = Np.start_run("x", :sandbox, ctx, %{}, "42")
      assert run.operator_id == "42"
      assert Np.get_run(run.id).operator_id == "42"

      # A ULID-shaped token.
      {:ok, run2} = Np.start_run("x", :sandbox, ctx, %{}, "01HX7K3JRWY8N3M5W6P9F1V2Q4")
      assert run2.operator_id == "01HX7K3JRWY8N3M5W6P9F1V2Q4"

      # nil still works (the common case where the runner is unattended).
      {:ok, run3} = Np.start_run("x", :sandbox, ctx, %{}, nil)
      assert run3.operator_id == nil
    end
  end

  describe "predicate vocabulary — sanity check each evaluator" do
    setup %{} do
      widget = TestRepo.insert!(%Np.Test.Widget{name: "w1", status: "draft"})
      gadget = TestRepo.insert!(%Np.Test.Gadget{label: "g1", widget_id: widget.id})
      %{widget: widget, gadget: gadget}
    end

    test "Exists — finds and binds the matched entity", %{widget: w} do
      pred = %Predicate.Exists{type: :widget, where: %{name: "w1"}, bind: :found}
      {:ok, bindings} = Np.Interpreter.evaluate(pred, %{})
      assert bindings.found.id == w.id
    end

    test "Exists — fails loudly when nothing matches" do
      pred = %Predicate.Exists{type: :widget, where: %{name: "no-such"}}
      assert {:fail, reason} = Np.Interpreter.evaluate(pred, %{})
      assert reason =~ "no widget matched"
    end

    test "None — passes when zero match" do
      pred = %Predicate.None{type: :widget, where: %{name: "missing"}}
      assert {:ok, _} = Np.Interpreter.evaluate(pred, %{})
    end

    test "Attribute — checks attribute on a bound entity", %{gadget: g} do
      pred = Predicate.attribute(Ref.new(:gadget), :enabled, :==, false)
      assert {:ok, _} = Np.Interpreter.evaluate(pred, %{gadget: g})
    end

    test "Relationship — verifies belongs-to via fk_for", %{widget: w, gadget: g} do
      pred = Predicate.relationship(Ref.new(:gadget), :widget, Ref.new(:widget))
      assert {:ok, _} = Np.Interpreter.evaluate(pred, %{widget: w, gadget: g})
    end

    test "ForAll — every entity satisfies the assert list", %{} do
      pred = %Predicate.ForAll{
        type: :gadget,
        assert: [Predicate.attribute(:it, :widget_id, :is_set)]
      }

      assert {:ok, _} = Np.Interpreter.evaluate(pred, %{})
    end
  end

  describe "picker callbacks — candidates_for / candidates_count / label_for" do
    test "candidates_for filters by where + paginates" do
      _ignored = TestRepo.insert!(%Np.Test.Widget{name: "ignored"})
      keep = TestRepo.insert!(%Np.Test.Widget{name: "keepme"})

      bind = Predicate.pick(:w, :widget, %{name: "keepme"}, "Pick a widget")

      assert [%{id: id}] = Np.Interpreter.candidates_for(bind, %{})
      assert id == keep.id
      assert 1 == Np.Interpreter.candidates_count(bind, %{})
    end

    test "label_for delegates to the adapter" do
      w = TestRepo.insert!(%Np.Test.Widget{name: "labelme"})
      assert Np.Interpreter.label_for(:widget, w) == "labelme"
    end

    test "search filter passes through to apply_search/3" do
      TestRepo.insert!(%Np.Test.Widget{name: "alpha"})
      TestRepo.insert!(%Np.Test.Widget{name: "beta"})

      bind = Predicate.pick(:w, :widget, %{}, "Pick")

      results = Np.Interpreter.candidates_for(bind, %{}, search: "alpha")
      assert Enum.map(results, & &1.name) == ["alpha"]
    end
  end
end
