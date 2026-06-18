defmodule PropertyDamage.Events.CommandSequenceTerminated do
  @moduledoc false

  @typedoc """
  Termination reason.
  """
  @type reason :: :model_terminated | :max_commands | :timeout | :injector_signal

  @typedoc """
  The command that triggered termination (index and module).
  """
  @type triggered_by :: {non_neg_integer(), module()} | nil

  @type t :: %__MODULE__{
          reason: reason(),
          triggered_by: triggered_by(),
          total_commands: non_neg_integer(),
          timestamp: DateTime.t() | integer()
        }

  defstruct [:reason, :triggered_by, :total_commands, :timestamp]

  @doc """
  Create a new termination event.

  ## Parameters

  - `reason` - Why command generation stopped
  - `opts` - Additional fields

  ## Options

  - `:triggered_by` - `{command_index, module}` if a command triggered it
  - `:total_commands` - Number of commands executed
  - `:timestamp` - When termination occurred (default: current UTC time)

  ## Examples

      CommandSequenceTerminated.new(:max_commands, total_commands: 100)

      CommandSequenceTerminated.new(:model_terminated,
        triggered_by: {5, CompletePayment},
        total_commands: 6
      )
  """
  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) do
    %__MODULE__{
      reason: reason,
      triggered_by: Keyword.get(opts, :triggered_by),
      total_commands: Keyword.get(opts, :total_commands, 0),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
    }
  end

  @doc """
  Check if termination was triggered by model logic.
  """
  @spec model_terminated?(t()) :: boolean()
  def model_terminated?(%__MODULE__{reason: :model_terminated}), do: true
  def model_terminated?(%__MODULE__{}), do: false

  @doc """
  Check if termination was due to reaching max commands.
  """
  @spec max_commands?(t()) :: boolean()
  def max_commands?(%__MODULE__{reason: :max_commands}), do: true
  def max_commands?(%__MODULE__{}), do: false

  @doc """
  Check if termination was due to timeout.
  """
  @spec timeout?(t()) :: boolean()
  def timeout?(%__MODULE__{reason: :timeout}), do: true
  def timeout?(%__MODULE__{}), do: false

  @doc """
  Get a human-readable description of the termination reason.
  """
  @spec reason_description(t()) :: String.t()
  def reason_description(%__MODULE__{reason: :model_terminated}), do: "model terminated"
  def reason_description(%__MODULE__{reason: :max_commands}), do: "max commands reached"
  def reason_description(%__MODULE__{reason: :timeout}), do: "timeout"
  def reason_description(%__MODULE__{reason: :injector_signal}), do: "injector signal"
end
