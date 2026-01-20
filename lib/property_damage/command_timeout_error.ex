defmodule PropertyDamage.CommandTimeoutError do
  @moduledoc """
  Raised when a command execution times out.

  This exception is raised by load test workers when a command takes longer
  than the configured timeout. The timeout is determined by the adapter's
  `timeout/1` callback.

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

      try do
        Worker.execute_sequence(worker)
      rescue
        e in PropertyDamage.CommandTimeoutError ->
          IO.puts("Command \#{inspect(e.command)} timed out after \#{e.timeout_ms}ms")
      end
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
