defmodule PropertyDamage.Telemetry.Events do
  @moduledoc """
  Common telemetry-derived events.

  These event structs represent common patterns observed in telemetry data.
  TelemetryReceiver implementations can convert spans to these events,
  and projections can track them for performance assertions.

  ## Example Usage

      defmodule MyReceiver do
        @behaviour PropertyDamage.TelemetryReceiver

        alias PropertyDamage.Telemetry.Events

        def to_event(%{name: "db.query", duration_ns: dur, attributes: attrs}) do
          {:ok, %Events.DatabaseQuery{
            duration_ms: dur / 1_000_000,
            operation: attrs["db.operation"],
            table: attrs["db.sql.table"]
          }}
        end

        def to_event(%{name: "http.client", attributes: %{"http.status_code" => code}})
            when code >= 500 do
          {:ok, %Events.ServiceError{
            status_code: code,
            service: attrs["http.host"]
          }}
        end

        def to_event(_), do: :skip
      end
  """

  defmodule DatabaseQuery do
    @moduledoc """
    Event representing a database query observed via telemetry.
    """
    defstruct [
      :duration_ms,
      :operation,
      :table,
      :rows_affected,
      :trace_id,
      :span_id
    ]

    @type t :: %__MODULE__{
            duration_ms: float(),
            operation: String.t() | nil,
            table: String.t() | nil,
            rows_affected: non_neg_integer() | nil,
            trace_id: String.t() | nil,
            span_id: String.t() | nil
          }
  end

  defmodule HTTPRequest do
    @moduledoc """
    Event representing an HTTP request observed via telemetry.
    """
    defstruct [
      :duration_ms,
      :method,
      :path,
      :status_code,
      :request_size,
      :response_size,
      :trace_id,
      :span_id
    ]

    @type t :: %__MODULE__{
            duration_ms: float(),
            method: String.t(),
            path: String.t(),
            status_code: non_neg_integer(),
            request_size: non_neg_integer() | nil,
            response_size: non_neg_integer() | nil,
            trace_id: String.t() | nil,
            span_id: String.t() | nil
          }
  end

  defmodule ServiceError do
    @moduledoc """
    Event representing an error response from an external service.
    """
    defstruct [
      :service,
      :status_code,
      :error_type,
      :message,
      :trace_id,
      :span_id
    ]

    @type t :: %__MODULE__{
            service: String.t(),
            status_code: non_neg_integer() | nil,
            error_type: String.t() | nil,
            message: String.t() | nil,
            trace_id: String.t() | nil,
            span_id: String.t() | nil
          }
  end

  defmodule RetryAttempt do
    @moduledoc """
    Event representing a retry attempt observed via telemetry.

    Useful for detecting retry storms that wouldn't be visible in business events.
    """
    defstruct [
      :operation,
      :attempt_number,
      :max_attempts,
      :delay_ms,
      :reason,
      :trace_id,
      :span_id
    ]

    @type t :: %__MODULE__{
            operation: String.t(),
            attempt_number: pos_integer(),
            max_attempts: pos_integer() | nil,
            delay_ms: non_neg_integer() | nil,
            reason: String.t() | nil,
            trace_id: String.t() | nil,
            span_id: String.t() | nil
          }
  end

  defmodule QueueOperation do
    @moduledoc """
    Event representing a message queue operation observed via telemetry.
    """
    defstruct [
      :operation,
      :queue_name,
      :duration_ms,
      :message_count,
      :trace_id,
      :span_id
    ]

    @type t :: %__MODULE__{
            operation: :publish | :consume | :ack | :nack,
            queue_name: String.t(),
            duration_ms: float() | nil,
            message_count: non_neg_integer(),
            trace_id: String.t() | nil,
            span_id: String.t() | nil
          }
  end

  defmodule CacheOperation do
    @moduledoc """
    Event representing a cache operation observed via telemetry.
    """
    defstruct [
      :operation,
      :cache_name,
      :hit,
      :duration_ms,
      :key_pattern,
      :trace_id,
      :span_id
    ]

    @type t :: %__MODULE__{
            operation: :get | :set | :delete | :expire,
            cache_name: String.t() | nil,
            hit: boolean() | nil,
            duration_ms: float() | nil,
            key_pattern: String.t() | nil,
            trace_id: String.t() | nil,
            span_id: String.t() | nil
          }
  end

  defmodule ConnectionPoolExhausted do
    @moduledoc """
    Event indicating connection pool exhaustion.

    This often manifests as increased latency rather than explicit errors,
    making it invisible in business events.
    """
    defstruct [
      :pool_name,
      :wait_time_ms,
      :pool_size,
      :active_connections,
      :trace_id,
      :span_id
    ]

    @type t :: %__MODULE__{
            pool_name: String.t(),
            wait_time_ms: float(),
            pool_size: non_neg_integer() | nil,
            active_connections: non_neg_integer() | nil,
            trace_id: String.t() | nil,
            span_id: String.t() | nil
          }
  end

  defmodule SlowOperation do
    @moduledoc """
    Generic event for operations exceeding a latency threshold.
    """
    defstruct [
      :operation_name,
      :duration_ms,
      :threshold_ms,
      :attributes,
      :trace_id,
      :span_id
    ]

    @type t :: %__MODULE__{
            operation_name: String.t(),
            duration_ms: float(),
            threshold_ms: float(),
            attributes: map(),
            trace_id: String.t() | nil,
            span_id: String.t() | nil
          }
  end
end
