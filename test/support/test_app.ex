defmodule Np.Test.App do
  @moduledoc """
  A minimal `Np.App` adapter for the package's own tests. Wires Np
  to two test-only schemas (`Widget`, `Gadget`) and a no-op
  factory/notification setup.
  """
  @behaviour Np.App

  import Ecto.Query

  alias Np.Test.{Gadget, Widget}
  alias Np.TestRepo

  @impl true
  def repo, do: Np.TestRepo

  @impl true
  def schema_for(:widget), do: Widget
  def schema_for(:gadget), do: Gadget

  @impl true
  def build_entity(:widget, where) do
    attrs = Map.merge(%{name: "widget-#{System.unique_integer([:positive])}"}, where)
    %Widget{} |> Ecto.Changeset.cast(attrs, [:name, :status]) |> TestRepo.insert!()
  end

  def build_entity(:gadget, where) do
    {assoc, rest} = Map.pop(where, :widget)

    attrs =
      %{label: "gadget-#{System.unique_integer([:positive])}"}
      |> Map.merge(rest)
      |> maybe_assoc_id(:widget_id, assoc)

    %Gadget{}
    |> Ecto.Changeset.cast(attrs, [:label, :enabled, :widget_id])
    |> TestRepo.insert!()
  end

  defp maybe_assoc_id(attrs, _, nil), do: attrs
  defp maybe_assoc_id(attrs, key, %{id: id}), do: Map.put(attrs, key, id)

  @impl true
  def fk_for(:widget), do: :widget_id
  def fk_for(other), do: String.to_atom(Atom.to_string(other) <> "_id")

  @impl true
  def apply_search(query, _type, nil), do: query
  def apply_search(query, _type, ""), do: query

  def apply_search(query, :widget, search),
    do: from(x in query, where: ilike(x.name, ^"%#{search}%"))

  def apply_search(query, :gadget, search),
    do: from(x in query, where: ilike(x.label, ^"%#{search}%"))

  def apply_search(query, _, _), do: query

  @impl true
  def preloads_for(:gadget), do: [:widget]
  def preloads_for(_), do: []

  @impl true
  def label_for(:widget, %{name: n}), do: n
  def label_for(:gadget, %{label: l}), do: l
  def label_for(_, %{id: id}), do: String.slice(id, 0, 8)

  @impl true
  def notification, do: nil

  @impl true
  def actions_module, do: Np.Test.Actions

  @impl true
  def invariants_module, do: Np.Test.Invariants
end

defmodule Np.Test.Actions do
  @behaviour Np.Actions

  @impl true
  def run(:enable_gadget, _actor, %{gadget: gadget}, _bindings) do
    updated =
      gadget
      |> Ecto.Changeset.change(%{enabled: true})
      |> Np.TestRepo.update!()

    {:ok, %{enabled_gadget: updated}}
  end

  def run(name, _, _, _), do: {:error, {:unknown_action, name}}
end

defmodule Np.Test.Invariants do
  @behaviour Np.Invariants

  alias Np.Predicate

  @impl true
  def standard do
    %{
      "every gadget has a name-bearing widget" => [
        %Predicate.ForAll{
          type: :gadget,
          assert: [Predicate.attribute(:it, :widget_id, :is_set)]
        }
      ]
    }
  end
end
