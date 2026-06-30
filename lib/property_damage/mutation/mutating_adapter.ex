defmodule PropertyDamage.Mutation.MutatingAdapter do
  @moduledoc false

  @behaviour PropertyDamage.Adapter

  defstruct [
    :inner_adapter,
    :inner_context,
    :target_command,
    :mutation,
    :operator,
    :mutation_applied,
    :apply_once
  ]

  @type t :: %__MODULE__{
          inner_adapter: module(),
          inner_context: map() | nil,
          target_command: module() | nil,
          mutation: map(),
          operator: module(),
          mutation_applied: boolean(),
          apply_once: boolean()
        }

  @doc """
  Creates a new mutating adapter wrapper.

  ## Options

  - `:inner_adapter` - The real adapter to wrap (required)
  - `:target_command` - Command module to mutate (nil = mutate all)
  - `:mutation` - The mutation specification to apply
  - `:operator` - The operator module that will apply the mutation
  - `:apply_once` - Only apply mutation once (default: true)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      inner_adapter: Keyword.fetch!(opts, :inner_adapter),
      inner_context: nil,
      target_command: Keyword.get(opts, :target_command),
      mutation: Keyword.fetch!(opts, :mutation),
      operator: Keyword.fetch!(opts, :operator),
      mutation_applied: false,
      apply_once: Keyword.get(opts, :apply_once, true)
    }
  end

  # ============================================================================
  # Adapter Callbacks
  # ============================================================================

  @impl PropertyDamage.Adapter
  def setup(%__MODULE__{} = adapter) do
    # Must precede the is_map clause: structs are maps, so the general
    # clause would otherwise swallow the adapter struct
    case adapter.inner_adapter.setup(%{}) do
      {:ok, inner_context} ->
        {:ok, %{adapter | inner_context: inner_context}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def setup(config) when is_map(config) do
    # Extract the mutating adapter from config if present
    case Map.get(config, :__mutating_adapter__) do
      %__MODULE__{} = adapter ->
        inner_config = Map.delete(config, :__mutating_adapter__)

        case adapter.inner_adapter.setup(inner_config) do
          {:ok, inner_context} ->
            {:ok, %{adapter | inner_context: inner_context}}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        {:error, :not_a_mutating_adapter}
    end
  end

  @impl PropertyDamage.Adapter
  def teardown(%{inner_adapter: inner_adapter, inner_context: inner_context}) do
    inner_adapter.teardown(inner_context)
  end

  def teardown(context) when is_map(context) do
    case Map.get(context, :__mutating_adapter__) do
      %__MODULE__{} = adapter ->
        teardown(adapter)

      nil ->
        :ok
    end
  end

  @impl PropertyDamage.Adapter
  def execute(command, user_context, runtime) do
    adapter = extract_adapter(user_context)
    inner_context = adapter.inner_context

    # Execute the real command, forwarding the Runtime handle to the inner adapter
    case adapter.inner_adapter.execute(command, inner_context, runtime) do
      {:ok, events} ->
        # Check if we should mutate this command's response
        if should_mutate?(command, adapter) do
          mutated_events = apply_mutation(events, adapter)
          # Mark mutation as applied if apply_once is true
          {:ok, mutated_events}
        else
          {:ok, events}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl PropertyDamage.Adapter
  def timeout(_command) do
    # Default timeout - inner adapter's timeout is used during actual execution
    # This is called when the adapter module itself is passed to the framework
    30
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp extract_adapter(%__MODULE__{} = adapter), do: adapter

  defp extract_adapter(context) when is_map(context) do
    Map.get(context, :__mutating_adapter__) || context
  end

  defp should_mutate?(command, adapter) do
    # Don't mutate if already applied and apply_once is true
    if adapter.apply_once and adapter.mutation_applied do
      false
    else
      # Check if this command matches the target
      case adapter.target_command do
        nil ->
          # No target specified, mutate all commands
          true

        target when is_atom(target) ->
          command.__struct__ == target
      end
    end
  end

  defp apply_mutation(events, adapter) do
    mutation = adapter.mutation
    operator = adapter.operator

    case operator.apply_mutation(events, mutation) do
      {:error, _reason} ->
        # If mutation fails, return original events
        events

      mutated_events when is_list(mutated_events) ->
        mutated_events
    end
  end

  @doc """
  Wraps an adapter module to use with PropertyDamage.run.

  Returns a configuration map that includes the mutating adapter.
  """
  @spec wrap_config(t(), map()) :: map()
  def wrap_config(%__MODULE__{} = adapter, base_config) do
    Map.put(base_config, :__mutating_adapter__, adapter)
  end

  @doc """
  Returns the inner adapter module.
  """
  @spec inner_adapter(t()) :: module()
  def inner_adapter(%__MODULE__{inner_adapter: adapter}), do: adapter
end
