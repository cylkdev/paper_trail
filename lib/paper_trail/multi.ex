defmodule PaperTrail.Multi do
  import Ecto.Changeset

  alias PaperTrail
  alias PaperTrail.Opts
  alias PaperTrail.Serializer

  defdelegate new(), to: Ecto.Multi
  defdelegate append(lhs, rhs), to: Ecto.Multi
  defdelegate error(multi, name, value), to: Ecto.Multi
  defdelegate merge(multi, merge), to: Ecto.Multi
  defdelegate merge(multi, mod, fun, args), to: Ecto.Multi
  defdelegate prepend(lhs, rhs), to: Ecto.Multi
  defdelegate run(multi, name, run), to: Ecto.Multi
  defdelegate run(multi, name, mod, fun, args), to: Ecto.Multi
  defdelegate to_list(multi), to: Ecto.Multi
  defdelegate make_version_struct(version, model, options), to: Serializer
  defdelegate serialize(data), to: Serializer
  defdelegate get_sequence_id(table_name), to: Serializer
  defdelegate add_prefix(schema, prefix), to: Serializer
  defdelegate get_item_type(data), to: Serializer
  defdelegate get_model_id(model, options), to: Serializer

  @default_options [
    origin: nil,
    meta: nil,
    originator: nil,
    prefix: nil,
    model_key: :model,
    version_key: :version,
    initial_version_key: :initial_version,
    ecto_options: []
  ]

  def insert(%Ecto.Multi{} = multi, changeset, options \\ @default_options) do
    options = Keyword.merge(@default_options, options)

    model_key = Keyword.fetch!(options, :model_key)
    version_key = Keyword.fetch!(options, :version_key)
    initial_version_key = Keyword.fetch!(options, :initial_version_key)
    ecto_options = Keyword.fetch!(options, :ecto_options)

    case Opts.strict_mode?(options) do
      true ->
        multi
        |> Ecto.Multi.run(initial_version_key, fn repo, %{} ->
          version_id = get_sequence_id("versions") + 1

          changeset
          |> Map.get(:data, changeset)
          |> Map.merge(%{
            id: get_sequence_id(changeset) + 1,
            first_version_id: version_id,
            current_version_id: version_id
          })
          |> make_version_struct(:insert, options)
          |> repo.insert(ecto_options)
        end)
        |> Ecto.Multi.run(model_key, fn repo, %{^initial_version_key => initial_version} ->
            changeset
            |> change(%{
              first_version_id: initial_version.id,
              current_version_id: initial_version.id
            })
            |> repo.insert(ecto_options)
        end)
        |> Ecto.Multi.run(version_key, fn repo, %{^initial_version_key => initial_version, ^model_key => model} ->
          model
          |> make_version_struct(:insert, options)
          |> serialize()
          |> then(&Opts.version_schema(options).changeset(initial_version, &1))
          |> repo.update(ecto_options)
        end)
      _ ->
        multi
        |> Ecto.Multi.insert(model_key, changeset, ecto_options)
        |> Ecto.Multi.run(version_key, fn repo, %{^model_key => model} ->
          model
          |> make_version_struct(:insert, options)
          |> repo.insert(ecto_options)
        end)
    end
  end

  def update(%Ecto.Multi{} = multi, changeset, options \\ @default_options) do
    model_key = options[:model_key] || :model
    version_key = options[:version_key] || :version
    initial_version_key = options[:initial_version_key] || :initial_version
    ecto_options = options[:ecto_options] || []

    case Opts.strict_mode?(options) do
      true ->
        multi
        |> Ecto.Multi.run(initial_version_key, fn repo, %{} ->
          version_data =
            changeset.data
            |> Map.merge(%{
              current_version_id: get_sequence_id("versions")
            })

          target_changeset = changeset |> Map.merge(%{data: version_data})
          target_version = make_version_struct(target_changeset, :update, options)
          repo.insert(target_version)
        end)
        |> Ecto.Multi.run(model_key, fn repo, %{^initial_version_key => initial_version} ->
          updated_changeset = changeset |> change(%{current_version_id: initial_version.id})
          repo.update(updated_changeset, Keyword.take(options, [:returning]))
        end)
        |> Ecto.Multi.run(version_key, fn repo, %{^initial_version_key => initial_version} ->
          new_item_changes =
            initial_version.item_changes
            |> Map.merge(%{
              current_version_id: initial_version.id
            })

          initial_version |> change(%{item_changes: new_item_changes}) |> repo.update
        end)

      _ ->
        multi
        |> Ecto.Multi.update(
          model_key,
          changeset,
          ecto_options ++ Keyword.take(options, [:returning])
        )
        |> Ecto.Multi.run(version_key, fn repo, %{^model_key => _model} ->
          version = make_version_struct(changeset, :update, options)
          repo.insert(version)
        end)
    end
  end

  def insert_or_update(%Ecto.Multi{} = multi, changeset, options \\ @default_options) do
    case get_state(changeset) do
      :built ->
        insert(multi, changeset, options)

      :loaded ->
        update(multi, changeset, options)

      state ->
        raise ArgumentError,
              "the changeset has an invalid state " <>
                "for PaperTrail.insert_or_update/2 or PaperTrail.insert_or_update!/2: #{state}"
    end
  end

  def delete(%Ecto.Multi{} = multi, struct, options \\ @default_options) do
    model_key = options[:model_key] || :model
    version_key = options[:version_key] || :version
    ecto_options = options[:ecto_options] || []

    multi
    |> Ecto.Multi.delete(model_key, struct, ecto_options)
    |> Ecto.Multi.run(version_key, fn repo, %{} ->
      version = make_version_struct(struct, :delete, options)
      repo.insert(version, options)
    end)
  end

  def commit(%Ecto.Multi{} = multi, opts \\ []) do
    repo = Opts.repo(opts)

    transaction = repo.transaction(multi)

    case Opts.strict_mode?(opts) do
      true ->
        case transaction do
          {:error, _, changeset, %{}} ->
            filtered_changes =
              Map.drop(changeset.changes, [:current_version_id, :first_version_id])

            {:error, Map.merge(changeset, %{repo: repo, changes: filtered_changes})}

          {:ok, map} ->
            {:ok, Map.drop(map, [:initial_version])}
        end

      _ ->
        case transaction do
          {:error, _, changeset, %{}} -> {:error, Map.merge(changeset, %{repo: repo})}
          _ -> transaction
        end
    end
  end

  defp get_state(%Ecto.Changeset{data: %{__meta__: %{state: state}}}), do: state

  defp get_state(%{__struct__: _}) do
    raise ArgumentError,
          "giving a struct to PaperTrail.insert_or_update/2 or " <>
            "PaperTrail.insert_or_update!/2 is not supported. " <>
            "Please use an Ecto.Changeset"
  end

end
