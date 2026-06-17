defmodule PropertyDamage.Progress.Reporter do
  @moduledoc """
  Synchronous, ordered fan-out of progress to consumers (DR-022), for the batch
  operations (`run`/`mutation`/`differential`).

  A reporter holds a list of consumer functions plus per-operation metadata.
  When there are no consumers it is *inert*: `emit/2` never invokes the build
  function, so an unobserved run allocates no `%Progress{}` on its hot loop.
  Consumers run in order, in the calling process; a raising/exiting consumer is
  caught and logged so it can never crash the operation (a slow consumer only
  lengthens the run, which is acceptable for batch operations).

  Load tests do not use this module — they dispatch through
  `PropertyDamage.Progress.Notifier`, an isolated process, so a slow consumer
  cannot stall load generation.
  """

  require Logger

  alias PropertyDamage.Progress

  @type consumer :: (Progress.t() -> any())

  @type t :: %__MODULE__{
          consumers: [consumer()],
          run_id: term(),
          started_at: integer()
        }

  @enforce_keys [:consumers, :run_id, :started_at]
  defstruct [:consumers, :run_id, :started_at]

  @doc """
  Build a reporter from a list of consumer functions.

  `nil` entries are dropped (so callers can pass `verbose? && printer`).
  Options: `:run_id` (correlation id, defaults to a fresh `make_ref/0`),
  `:started_at` (monotonic ms, defaults to now).
  """
  @spec new([consumer() | nil], keyword()) :: t()
  def new(consumers, opts \\ []) do
    %__MODULE__{
      consumers: Enum.reject(consumers, &is_nil/1),
      run_id: Keyword.get_lazy(opts, :run_id, &make_ref/0),
      started_at:
        Keyword.get_lazy(opts, :started_at, fn -> System.monotonic_time(:millisecond) end)
    }
  end

  @doc "Whether the reporter has any consumers (i.e. whether emitting does anything)."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{consumers: []}), do: false
  def active?(%__MODULE__{}), do: true

  @doc """
  Build a progress value and fan it out to the consumers, in order.

  `build` is a zero-arity function returning the payload struct. It is invoked
  lazily and only when there is at least one consumer, so an inert reporter
  allocates nothing.
  """
  @spec emit(t(), (-> Progress.payload())) :: :ok
  def emit(%__MODULE__{consumers: []}, _build), do: :ok

  def emit(%__MODULE__{} = reporter, build) when is_function(build, 0) do
    progress =
      Progress.new(build.(),
        at: System.system_time(:millisecond),
        elapsed_ms: System.monotonic_time(:millisecond) - reporter.started_at,
        run_id: reporter.run_id
      )

    dispatch(reporter.consumers, progress)
  end

  @doc """
  Apply an already-built progress value to a consumer list, in order, with each
  consumer guarded. Shared with `PropertyDamage.Progress.Notifier`.
  """
  @spec dispatch([consumer()], Progress.t()) :: :ok
  def dispatch(consumers, %Progress{} = progress) do
    Enum.each(consumers, &guarded(&1, progress))
  end

  defp guarded(consumer, progress) do
    consumer.(progress)
    :ok
  rescue
    e ->
      Logger.error(
        "PropertyDamage progress consumer raised and was skipped " <>
          "(#{inspect(Progress.telemetry_event(progress))}):\n" <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "PropertyDamage progress consumer #{kind} and was skipped " <>
          "(#{inspect(Progress.telemetry_event(progress))}):\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      :ok
  end
end
