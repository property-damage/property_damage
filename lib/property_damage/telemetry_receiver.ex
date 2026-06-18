defmodule PropertyDamage.TelemetryReceiver do
  @moduledoc false

  @doc """
  Setup the telemetry receiver.

  Called once before test execution begins. Should start any servers,
  consumers, or connections needed to receive telemetry.

  ## Parameters

  - `config` - Configuration map, typically containing:
    - `:event_queue` - EventQueue pid to push events to
    - `:port` - Port to listen on (for HTTP receivers)
    - `:run_id` - Unique identifier for this test run

  ## Returns

  - `{:ok, context}` - Context map passed to teardown/1
  - `{:error, reason}` - Setup failed
  """
  @callback setup(config :: map()) :: {:ok, context :: map()} | {:error, term()}

  @doc """
  Teardown the telemetry receiver.

  Called after test execution completes. Should clean up any resources.
  """
  @callback teardown(context :: map()) :: :ok

  @doc """
  Convert a telemetry span to a test event.

  Called for each span received. Return `:skip` for spans that aren't
  relevant to your test.

  ## Parameters

  - `span` - The telemetry span, typically containing:
    - `:name` - Span name (e.g., "db.query", "http.client")
    - `:duration_ns` - Duration in nanoseconds
    - `:attributes` - Map of span attributes
    - `:trace_id` - Trace identifier
    - `:span_id` - Span identifier
    - `:parent_span_id` - Parent span (for causality)

  ## Returns

  - `{:ok, event}` - Convert to this event struct
  - `:skip` - Ignore this span
  """
  @callback to_event(span :: map()) :: {:ok, struct()} | :skip

  # ============================================================================
  # Utility Functions
  # ============================================================================

  @doc """
  Generate a W3C Trace Context traceparent header value.

  ## Example

      traceparent = TelemetryReceiver.format_traceparent(trace_id, span_id)
      # => "00-abc123...-def456...-01"
  """
  @spec format_traceparent(String.t(), String.t(), keyword()) :: String.t()
  def format_traceparent(trace_id, span_id, opts \\ []) do
    version = Keyword.get(opts, :version, "00")
    flags = Keyword.get(opts, :flags, "01")
    "#{version}-#{trace_id}-#{span_id}-#{flags}"
  end

  @doc """
  Parse a W3C Trace Context traceparent header value.

  ## Example

      {:ok, %{trace_id: t, span_id: s}} = TelemetryReceiver.parse_traceparent(header)
  """
  @spec parse_traceparent(String.t()) :: {:ok, map()} | {:error, :invalid_format}
  def parse_traceparent(header) do
    case String.split(header, "-") do
      [version, trace_id, span_id, flags] ->
        {:ok,
         %{
           version: version,
           trace_id: trace_id,
           span_id: span_id,
           flags: flags
         }}

      _ ->
        {:error, :invalid_format}
    end
  end

  @doc """
  Generate a random trace ID (32 hex characters).
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc """
  Generate a random span ID (16 hex characters).
  """
  @spec generate_span_id() :: String.t()
  def generate_span_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
