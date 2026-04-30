defmodule Np.Test.Widget do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "widgets" do
    field :name, :string
    field :status, :string, default: "draft"
    timestamps()
  end
end

defmodule Np.Test.Gadget do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gadgets" do
    field :label, :string
    field :enabled, :boolean, default: false
    belongs_to :widget, Np.Test.Widget
    timestamps()
  end
end
