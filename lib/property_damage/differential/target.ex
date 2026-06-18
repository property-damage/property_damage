defmodule PropertyDamage.Differential.Target do
  @moduledoc false

  @type t :: %__MODULE__{
          adapter: module(),
          name: String.t(),
          role: :reference | :candidate,
          opts: map()
        }

  defstruct [:adapter, :name, :role, :opts]

  @doc """
  Parse a target specification into a Target struct.

  ## Target Specification Formats

      # Just adapter module
      {MyAdapter}

      # With name
      {MyAdapter, name: "staging"}

      # As reference
      {MyAdapter, role: :reference}

      # With adapter options
      {MyAdapter, name: "prod", opts: [url: "https://prod.example.com"]}

      # Full specification
      {MyAdapter, name: "prod", role: :reference, opts: [pool_size: 10]}
  """
  @spec parse(tuple(), non_neg_integer()) :: t()
  def parse(spec, index) do
    {adapter, opts} =
      case spec do
        {adapter} when is_atom(adapter) ->
          {adapter, []}

        {adapter, opts} when is_atom(adapter) and is_list(opts) ->
          {adapter, opts}

        adapter when is_atom(adapter) ->
          {adapter, []}
      end

    name = Keyword.get(opts, :name) || derive_name(adapter, index)
    role = Keyword.get(opts, :role, :candidate)
    adapter_opts = Keyword.get(opts, :opts, %{}) |> to_map()

    %__MODULE__{
      adapter: adapter,
      name: name,
      role: role,
      opts: adapter_opts
    }
  end

  defp derive_name(adapter, index) do
    # Derive name from module name
    module_name =
      adapter
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.replace("_adapter", "")

    "#{module_name}_#{index}"
  end

  defp to_map(opts) when is_map(opts), do: opts
  defp to_map(opts) when is_list(opts), do: Map.new(opts)
end
