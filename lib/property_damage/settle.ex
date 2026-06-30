defmodule PropertyDamage.Settle do
  @moduledoc """
  Settle logic for eventually consistent systems.

  The Settle module provides retry logic for probe and async commands that need
  to wait for eventual consistency. It supports configurable timeout, interval,
  and backoff strategies.

  ## Usage

  Commands whose `command_spec/1` declares `execution: :probe` or `:async` customize
  retry behavior via the spec's `:settle` map. The Executor uses this module to
  repeatedly execute the command until it succeeds or times out.

  ## Example

      defmodule MyProbe do
        use PropertyDamage.Command,
          execution: :probe,
          settle: %{timeout_ms: 5_000, interval_ms: 200, backoff: :exponential}

        defstruct []

        @impl true
        def generator(_overrides \\\\ %{}), do: StreamData.constant(%{})
      end

  ## Backoff Strategies

  - `:linear` - Constant interval between retries (default)
  - `:exponential` - Double the interval after each retry (capped at timeout)
  """

  # Matches Command.framework_defaults/0 and the eventual-consistency spec
  # (interval was previously 100 here, a 3-way mismatch with both).
  @default_config %{
    timeout_ms: 2_000,
    interval_ms: 300,
    backoff: :linear
  }

  @doc """
  Get the settle configuration for a command.

  For a command module/struct, resolves the `:settle` map from its `command_spec/1`
  (falling back to defaults when the command has no spec). Also accepts a command
  spec map directly via its `:settle` key.
  """
  @spec get_config(module() | struct() | map()) :: map()
  def get_config(command) when is_struct(command) do
    get_config(command.__struct__)
  end

  def get_config(command_module) when is_atom(command_module) do
    get_settle_config(resolve_spec(command_module))
  end

  # Spec map with :settle key
  def get_config(%{settle: settle}) when is_map(settle) do
    Map.merge(@default_config, settle)
  end

  # Plain map without :settle - use defaults
  def get_config(map) when is_map(map), do: @default_config

  @doc """
  Get the execution mode from a command spec map.

  Returns the :execution value from the spec map, or :sync if not present.
  """
  @spec get_execution(map()) :: :sync | :probe | :async
  def get_execution(%{execution: execution}), do: execution
  def get_execution(_), do: :sync

  @doc """
  Get the settle configuration from a command spec map.

  Returns the :settle value from the spec map merged with defaults.
  """
  @spec get_settle_config(map()) :: map()
  def get_settle_config(%{settle: settle}) when is_map(settle) do
    Map.merge(@default_config, settle)
  end

  def get_settle_config(_), do: @default_config

  @doc """
  Get the execution semantics of a command.

  For a command module/struct, resolves `:execution` from its `command_spec/1`
  (`:sync` when the command has no spec). Also accepts a command spec map with an
  `:execution` key.
  """
  @spec get_semantics(module() | struct() | map()) :: :sync | :probe | :async
  def get_semantics(command) when is_struct(command) do
    get_semantics(command.__struct__)
  end

  def get_semantics(command_module) when is_atom(command_module) do
    Map.get(resolve_spec(command_module), :execution, :sync)
  end

  # Spec map with :execution key
  def get_semantics(%{execution: execution}), do: execution

  # Plain maps are always sync
  def get_semantics(map) when is_map(map), do: :sync

  # Resolve a command module's spec via its command_spec/1, falling back to the
  # framework defaults for spec-less command modules (DR-028: command_spec is the
  # single static-metadata surface; there is no per-callback fallback).
  defp resolve_spec(command_module) do
    if function_exported?(command_module, :command_spec, 1) do
      command_module.command_spec([])
    else
      PropertyDamage.Command.framework_defaults()
    end
  end

  @doc """
  Check if a command requires settling (is a probe or async).
  """
  @spec requires_settling?(module() | struct()) :: boolean()
  def requires_settling?(command) do
    get_semantics(command) in [:probe, :async]
  end

  @doc """
  Execute a function with settle/retry logic.

  The function should return:
  - `{:ok, result}` - Success, stop retrying
  - `{:settled, result}` - Successfully settled, stop retrying
  - `{:retry, reason}` - Need to retry (will continue until timeout)
  - `{:error, reason}` - Hard failure, stop retrying immediately

  ## Options

  - `:timeout_ms` - Maximum time to wait (default: 2000)
  - `:interval_ms` - Time between retries (default: 300)
  - `:backoff` - Backoff strategy, `:linear` or `:exponential` (default: `:linear`)

  ## Returns

  - `{:ok, result}` - Function succeeded
  - `{:settled, result}` - Function settled successfully
  - `{:timeout, last_reason}` - Timed out waiting for success
  - `{:error, reason}` - Function returned hard error
  """
  @type settle_result ::
          {:ok, term()}
          | {:settled, term()}
          | {:retry, term()}
          | {:timeout, term()}
          | {:error, term()}

  @spec settle((-> settle_result()), keyword()) :: settle_result()
  def settle(fun, opts \\ []) do
    config = Keyword.merge(Map.to_list(@default_config), opts)
    timeout_ms = Keyword.get(config, :timeout_ms)
    interval_ms = Keyword.get(config, :interval_ms)
    backoff = Keyword.get(config, :backoff)

    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_settle(fun, deadline, interval_ms, backoff)
  end

  defp do_settle(fun, deadline, interval_ms, backoff) do
    # Attempt first, THEN decide whether to retry. This guarantees the function
    # runs at least once (e.g. with timeout_ms: 0) and that a final attempt is
    # made at the deadline rather than bailing out just before it.
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:settled, result} ->
        {:settled, result}

      {:retry, reason} ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:timeout, reason}
        else
          remaining = deadline - now
          sleep_time = min(interval_ms, remaining)

          if sleep_time > 0 do
            Process.sleep(sleep_time)
          end

          next_interval =
            case backoff do
              :exponential -> min(interval_ms * 2, remaining)
              :linear -> interval_ms
            end

          do_settle(fun, deadline, next_interval, backoff)
        end

      {:error, reason} ->
        {:error, reason}

      # A return outside the settle protocol is a contract violation (e.g. a
      # malformed adapter return); surface it as an error rather than laundering
      # it into a success.
      other ->
        {:error, {:malformed_settle_return, other}}
    end
  end

  @doc """
  Execute a command with settle logic if required.

  If the command is a probe or async, wraps execution with settle/retry logic.
  For regular sync commands, executes directly.

  ## Parameters

  - `command` - The command struct
  - `execute_fn` - Function that executes the command, should return settle-compatible result
  - `opts` - Additional options (merged with command's settle_config)
  """
  @spec execute_with_settle(struct(), (-> term()), keyword()) :: term()
  def execute_with_settle(command, execute_fn, opts \\ []) do
    if requires_settling?(command) do
      config = get_config(command)
      merged_opts = Keyword.merge(Map.to_list(config), opts)
      settle(execute_fn, merged_opts)
    else
      # Regular action - execute directly
      execute_fn.()
    end
  end
end
