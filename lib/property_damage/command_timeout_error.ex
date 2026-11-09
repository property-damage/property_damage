defmodule PropertyDamage.CommandTimeoutError do
  @moduledoc """
  The adapter error of a command whose execution times out.

  The engine stops a command that takes longer than the adapter's `timeout/1`
  and reports this exception as the command's error. A load test counts it as
  an error and goes on with the sequence; a property run reports it as a
  failure.

  ## Fields

  - `:command` - The command struct that timed out
  - `:timeout_ms` - The timeout value in milliseconds
  - `:message` - Human-readable error message

  ## Adjusting Timeouts

  To change the timeout for a specific command, override the `timeout/1`
  callback in your adapter:

      defmodule MyAdapter do
        use PropertyDamage.Adapter, default_timeout: 30

        # Override for slow polling command
        def timeout(%CreateAuthorization{}), do: 120
      end

  ## Example

  A load test counts the timed-out command as an error:

      {:ok, report} = PropertyDamage.LoadTest.run(opts)
      report.metrics.total_errors
  """

  defexception [:message, :command, :timeout_ms]

  @impl true
  def exception(opts) do
    command = opts[:command]
    timeout_ms = opts[:timeout_ms]
    command_name = command.__struct__ |> to_string() |> String.replace("Elixir.", "")

    %__MODULE__{
      message: "Command #{command_name} timed out after #{timeout_ms}ms",
      command: command,
      timeout_ms: timeout_ms
    }
  end
end
