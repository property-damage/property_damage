defmodule PropertyDamage.Mutation.MutatingAdapter do
  @moduledoc false

  @behaviour PropertyDamage.Adapter

  defstruct [
    :inner_adapter,
    :inner_context,
    :target_command,
    :mutation,
    :operator,
    :applied_count,
    :apply_once
  ]

  @type t :: %__MODULE__{
          inner_adapter: module(),
          inner_context: map() | nil,
          target_command: module() | nil,
          mutation: map(),
          operator: module(),
          applied_count: :atomics.atomics_ref(),
          apply_once: boolean()
        }

  @doc """
  Creates a new mutating adapter wrapper.

  ## Options

  - `:inner_adapter` - The real adapter to wrap (required)
  - `:target_command` - Command module to mutate (nil = mutate all)
  - `:mutation` - The mutation specification to apply
  - `:operator` - The operator module that will apply the mutation
  - `:apply_once` - Only apply mutation once per run (default: true)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    # `execute/3` runs in a short-lived child process and the framework never
    # threads updated context back between commands, so a plain struct field
    # cannot track "already applied". A shared `:atomics` counter can: it is a
    # reference to mutable memory that survives message passing across processes
    # (see the adapter cross-process notes in `PropertyDamage.Adapter`).
    %__MODULE__{
      inner_adapter: Keyword.fetch!(opts, :inner_adapter),
      inner_context: nil,
      target_command: Keyword.get(opts, :target_command),
      mutation: Keyword.fetch!(opts, :mutation),
      operator: Keyword.fetch!(opts, :operator),
      applied_count: :atomics.new(1, signed: false),
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
        reset_applied(adapter)
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
            reset_applied(adapter)
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
        # Mutate this command's response only when it matches the target and
        # this adapter is still allowed to apply (apply_once budget not spent).
        if should_mutate?(command, adapter) and claim_application(adapter) do
          apply_mutation(events, adapter)
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
    # Check if this command matches the target
    case adapter.target_command do
      nil ->
        # No target specified, mutate all commands
        true

      target when is_atom(target) ->
        command.__struct__ == target
    end
  end

  # Claim the right to apply the mutation. With apply_once the mutation is
  # injected at most once per run: the first matching command wins, later ones
  # pass through unmutated. The atomic increment makes this safe even though
  # each command executes in its own process.
  defp claim_application(%__MODULE__{apply_once: false}), do: true

  defp claim_application(%__MODULE__{apply_once: true, applied_count: ref}) do
    :atomics.add_get(ref, 1, 1) == 1
  end

  defp reset_applied(%__MODULE__{applied_count: ref}) do
    :atomics.put(ref, 1, 0)
  end

  defp apply_mutation(events, adapter) do
    mutation = adapter.mutation
    operator = adapter.operator

    case operator.apply_mutation(events, mutation) do
      {:error, reason} ->
        # An operator that returns an error tuple has *applied* its mutation:
        # the intended output is an error response (e.g. a status
        # :success_to_error mutation). Flow it through as this command's
        # result. A mutation that merely fails to apply returns the events
        # unchanged (a list), so it is not conflated with this case.
        {:error, reason}

      mutated_events when is_list(mutated_events) ->
        {:ok, mutated_events}
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
