defmodule Np.Runners.PlaywrightTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Np.Runners.Playwright
  alias Np.{Test.Widget, TestRepo}

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  describe "serialize_bindings/1" do
    test "serializes each entity as type + id + display fields" do
      widget =
        TestRepo.insert!(%Widget{name: "alpha", status: "draft"})

      bindings = %{thing: widget}

      assert %{
               "thing" => %{
                 "type" => "widget",
                 "id" => id,
                 "display" => %{"name" => "alpha"}
               }
             } = Playwright.serialize_bindings(bindings)

      assert id == widget.id
    end

    test "drops nil and empty display values" do
      widget = TestRepo.insert!(%Widget{name: "beta", status: ""})
      assert %{"thing" => %{"display" => display}} =
               Playwright.serialize_bindings(%{thing: widget})

      refute Map.has_key?(display, "status")
      assert display["name"] == "beta"
    end
  end

  describe "build_fixture/4" do
    test "produces a JSON-friendly map shape" do
      run = %Np.Run{id: "11111111-1111-1111-1111-111111111111"}
      scenario = %Np.Scenario{
        id: "place-order",
        title: "t",
        preconditions: [],
        action: %Np.Action{name: :place_order},
        postconditions: []
      }

      widget = TestRepo.insert!(%Widget{name: "abc"})
      prompt = %{title: "Do the thing", body: "1. step", goto: "/x"}

      fixture = Playwright.build_fixture(run, scenario, %{w: widget}, prompt)

      assert fixture["run_id"] == run.id
      assert fixture["scenario_id"] == "place-order"
      assert fixture["bindings"]["w"]["display"]["name"] == "abc"
      assert fixture["prompt"] == prompt

      # Must round-trip through JSON without raising.
      json = Jason.encode!(fixture)
      decoded = Jason.decode!(json)
      assert decoded["run_id"] == run.id
    end
  end
end
