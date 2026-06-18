defmodule PropertyDamage.Telemetry.Events do
  @moduledoc false

  defmodule DatabaseQuery do
    @moduledoc false
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
    @moduledoc false
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
    @moduledoc false
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
    @moduledoc false
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
    @moduledoc false
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
    @moduledoc false
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
    @moduledoc false
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
    @moduledoc false
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
