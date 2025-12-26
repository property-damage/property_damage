defmodule PropertyDamage.Settle do
  @moduledoc """
  Settle logic for eventually consistent systems.

  The Settle module provides retry logic for probe and bridge commands that need
  to wait for eventual consistency. It supports configurable timeout, interval,
  and backoff strategies.

  ## Usage

  Commands with `role/0` returning `:probe` or `:bridge` can implement `settle_config/0`
  to customize retry behavior. The Executor uses this module to repeatedly execute
  the command until it succeeds or times out.

  ## Example

      defmodule MyProbe do
        @behaviour PropertyDamage.Command

        def role, do: :probe

        def settle_config do
          %{
            timeout_ms: 5_000,
            interval_ms: 200,
            backoff: :exponential
          }
        end
      end

  ## Backoff Strategies

  - `:linear` - Constant interval between retries (default)
  - `:exponential` - Double the interval after each retry (capped at timeout)
  """

  @default_config %{
    timeout_ms: 2_000,
    interval_ms: 100,
    backoff: :linear
  }

  @doc """
  Get the settle configuration for a command.

  Returns the command's settle_config if implemented, otherwise returns defaults.
  """
  @spec get_config(module() | struct()) :: map()
  def get_config(command) when is_struct(command) do
    get_config(command.__struct__)
  end

  def get_config(command_module) when is_atom(command_module) do
    if function_exported?(command_module, :settle_config, 0) do
      Map.merge(@default_config, command_module.settle_config())
    else
      @default_config
    end
  end

  @doc """
  Get the role of a command.

  Returns the command's role if implemented, otherwise returns :action (default).
  """
  @spec get_role(module() | struct() | map()) :: :action | :probe | :bridge | :mock_config
  def get_role(command) when is_struct(command) do
    get_role(command.__struct__)
  end

  def get_role(command_module) when is_atom(command_module) do
    if function_exported?(command_module, :role, 0) do
      command_module.role()
    else
      :action
    end
  end

  # Plain maps are always actions
  def get_role(command) when is_map(command), do: :action

  @doc """
  Check if a command requires settling (is a probe or bridge).
  """
  @spec requires_settling?(module() | struct()) :: boolean()
  def requires_settling?(command) do
    get_role(command) in [:probe, :bridge]
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
  - `:interval_ms` - Time between retries (default: 100)
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

    do_settle(fun, deadline, interval_ms, backoff, nil)
  end

  defp do_settle(fun, deadline, interval_ms, backoff, last_reason) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:timeout, last_reason}
    else
      case fun.() do
        {:ok, result} ->
          {:ok, result}

        {:settled, result} ->
          {:settled, result}

        {:retry, reason} ->
          # Sleep and retry
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

          do_settle(fun, deadline, next_interval, backoff, reason)

        {:error, reason} ->
          {:error, reason}

        # Handle legacy returns that don't use the settle protocol
        other ->
          {:ok, other}
      end
    end
  end

  @doc """
  Execute a command with settle logic if required.

  If the command is a probe or bridge, wraps execution with settle/retry logic.
  For regular actions, executes directly.

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
