defmodule LocationType do
  use Ecto.Type

  defstruct [:country]

  @impl true
  def type, do: :map

  @impl true
  def embed_as(_format), do: :dump

  @impl true
  def cast(%__MODULE__{} = location), do: {:ok, location}
  def cast(%{} = data), do: {:ok, struct!(__MODULE__, data)}
  def cast(_), do: :error

  @impl true
  def load(data) when is_map(data) do
    data = Enum.map(data, fn {key, val} -> {String.to_existing_atom(key), val} end)

    {:ok, struct!(__MODULE__, data)}
  end

  @impl true
  def dump(%__MODULE__{} = location), do: {:ok, Map.from_struct(location)}
  def dump(_), do: :error
end

defmodule SimpleCompany do
  use Ecto.Schema

  alias PaperTrailTest.MultiTenantHelper, as: MultiTenant

  import Ecto.Changeset
  import Ecto.Query

  schema "simple_companies" do
    field(:name, :string)
    field(:is_active, :boolean)
    field(:website, :string)
    field(:city, :string)
    field(:address, :string)
    field(:facebook, :string)
    field(:twitter, :string)
    field(:founded_in, :string)
    field(:location, LocationType)

    has_many(:people, SimplePerson, foreign_key: :company_id)

    timestamps()
  end

  @optional_fields ~w(
    name
    is_active
    website
    city
    address
    facebook
    twitter
    founded_in
    location
  )a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @optional_fields)
    |> validate_required([:name])
    |> no_assoc_constraint(:people)
  end

  def count do
    from(record in __MODULE__, select: count(record.id)) |> PaperTrail.Opt.repo().one
  end

  def count(:multitenant) do
    from(record in __MODULE__, select: count(record.id))
    |> MultiTenant.add_prefix_to_query()
    |> PaperTrail.Opt.repo().one
  end
end

defmodule SimplePerson do
  use Ecto.Schema

  alias PaperTrailTest.MultiTenantHelper, as: MultiTenant

  import Ecto.Changeset
  import Ecto.Query

  schema "simple_people" do
    field(:first_name, :string)
    field(:last_name, :string)
    field(:visit_count, :integer)
    field(:gender, :boolean)
    field(:birthdate, :date)

    belongs_to(:company, SimpleCompany, foreign_key: :company_id)

    embeds_one(:singular, SimpleEmbed, on_replace: :update)
    embeds_many(:plural, SimpleEmbed)

    timestamps()
  end

  @optional_fields ~w(
    first_name
    last_name
    visit_count
    gender
    birthdate
    company_id
  )a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @optional_fields)
    |> foreign_key_constraint(:company_id)
    |> cast_embed(:singular)
    |> cast_embed(:plural)
  end

  def count do
    from(record in __MODULE__, select: count(record.id)) |> PaperTrail.Opt.repo().one
  end

  def count(:multitenant) do
    from(record in __MODULE__, select: count(record.id))
    |> MultiTenant.add_prefix_to_query()
    |> PaperTrail.Opt.repo().one
  end
end

defmodule SimpleEmbed do
  use Ecto.Schema

  import Ecto.Changeset

  embedded_schema do
    field(:name, :string)
  end

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:name])
  end
end
