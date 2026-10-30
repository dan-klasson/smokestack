defmodule Smokestack.RecordBuilder do
  @moduledoc """
  Handles the insertion of new records.
  """

  alias Ash.{Resource, Seed}
  alias Smokestack.{Builder, Dsl.Factory, ManyBuilder, RelatedBuilder}
  alias Spark.Options
  @behaviour Builder

  @type option :: load_option | tenant_option | ManyBuilder.option() | RelatedBuilder.option()

  @typedoc "A nested keyword list of associations, calculations and aggregates to load"
  @type load_option :: {:load, Smokestack.recursive_atom_list()}

  @typedoc "The tenant to seed the record into"
  @type tenant_option :: {:tenant, term()}

  @type result :: Resource.record() | [Resource.record()]
  @type error ::
          RelatedBuilder.error()
          | ManyBuilder.error()
          | Ash.Error.t()

  @doc """
  Run the factory and insert a record, or records.
  """
  @impl true
  @spec build(Factory.t(), [option]) :: {:ok, result} | {:error, error}
  def build(factory, options) do
    {tenant, options} = Keyword.pop(options, :tenant)
    {count, options} = Keyword.pop(options, :count)
    do_build(factory, options, count, tenant)
  end

  @doc false
  @impl true
  @spec option_schema(nil | Factory.t()) :: {:ok, Options.schema(), String.t()} | {:error, error}
  def option_schema(factory) do
    with {:ok, related_schema, related_section} <- RelatedBuilder.option_schema(factory),
         {:ok, many_schema, many_section} <- ManyBuilder.option_schema(factory) do
      load_type =
        if factory do
          loadable_names =
            factory.resource
            |> Resource.Info.relationships()
            |> Enum.concat(Resource.Info.aggregates(factory.resource))
            |> Enum.concat(Resource.Info.calculations(factory.resource))
            |> Enum.map(& &1.name)
            |> Enum.uniq()

          {:or,
           [
             {:wrap_list, {:in, loadable_names}},
             {:keyword_list,
              Enum.map(
                loadable_names,
                &{&1, type: {:or, [:atom, :keyword_list]}, required: false}
              )}
           ]}
        else
          {:or, [{:wrap_list, :atom}, :keyword_list]}
        end

      many_schema =
        Keyword.update!(many_schema, :count, fn current ->
          current
          |> Keyword.update!(:type, &{:or, [&1, nil]})
          |> Keyword.put(:default, nil)
          |> Keyword.put(:required, false)
        end)

      schema =
        [
          tenant: [
            type: :any,
            required: false,
            doc: """
            The tenant to seed the record into.

            For example:

                insert!(Post, tenant: "my-tenant")
            """
          ],
          load: [
            type: load_type,
            required: false,
            default: [],
            doc: """
            An optional Ash load statement.

            You can request any calculations, aggregates or relationships you
            would like loaded on the returned record.

            For example:

            ```elixir
            insert!(Post, load: [:full_title])
            assert is_binary(post.full_title)
            ```
            """
          ]
        ]
        |> Options.merge(many_schema, many_section)
        |> Options.merge(related_schema, related_section)

      {:ok, schema, "Options for building records"}
    end
  end

  defp do_build(factory, options, count, tenant) when is_integer(count) and count > 0 do
    {load, options} = Keyword.pop(options, :load, [])
    options = Keyword.put(options, :count, count)

    with {:ok, attr_list} <- ManyBuilder.build(factory, options),
         {:ok, record_list} <- seed(attr_list, factory, tenant) do
      record_list
      |> maybe_hook(factory)
      |> maybe_load(factory, List.wrap(load), tenant)
    end
  end

  defp do_build(factory, options, _count, tenant) do
    {load, options} = Keyword.pop(options, :load, [])

    with {:ok, attrs} <- RelatedBuilder.build(factory, options),
         {:ok, record} <- seed(attrs, factory, tenant) do
      record
      |> maybe_hook(factory)
      |> maybe_load(factory, List.wrap(load), tenant)
    end
  end

  defp seed(attr_list, factory, tenant) when is_list(attr_list) do
    records =
      factory.resource
      |> Seed.seed!(attr_list, seed_options(tenant))
      |> Enum.map(&set_meta(&1, factory))

    {:ok, records}
  rescue
    error -> {:error, error}
  end

  defp seed(attrs, factory, tenant) do
    record =
      factory.resource
      |> Seed.seed!(attrs, seed_options(tenant))
      |> set_meta(factory)

    {:ok, record}
  rescue
    error -> {:error, error}
  end

  defp seed_options(nil), do: []
  defp seed_options(tenant), do: [tenant: tenant]

  defp set_meta(record, factory) do
    record
    |> Resource.put_metadata(:factory, factory.module)
    |> Resource.put_metadata(:variant, factory.variant)
  end

  defp maybe_load(record_or_records, %{auto_load: []}, [], _tenant),
    do: {:ok, record_or_records}

  defp maybe_load(_record_or_records, factory, _load, _tenant) when is_nil(factory.domain),
    do: {:error, "Unable to perform `load` operation without an Domain."}

  defp maybe_load(record_or_records, factory, load, tenant) do
    load =
      factory.auto_load
      |> Enum.concat(load)

    opts =
      [domain: factory.domain]
      |> then(fn opts -> if tenant, do: Keyword.put(opts, :tenant, tenant), else: opts end)

    Ash.load(record_or_records, load, opts)
  end

  defp maybe_hook(records, factory) when is_list(records) do
    Enum.map(records, fn record ->
      Enum.reduce(factory.after_build, record, fn hook, record ->
        hook.(record)
      end)
    end)
  end

  defp maybe_hook(record, factory) when is_map(record) do
    Enum.reduce(factory.after_build, record, fn hook, record ->
      hook.hook.(record)
    end)
  end
end
