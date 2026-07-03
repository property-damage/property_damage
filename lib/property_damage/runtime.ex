defmodule PropertyDamage.Runtime do
  @moduledoc """
  The framework runtime handle passed to `c:PropertyDamage.Adapter.execute/3` (DR-027).

  `execute/3` receives three arguments, keeping the user's *served* data and the
  framework's *servant* plumbing in separate channels:

      def execute(%CreateOrder{} = cmd, user_context, %PropertyDamage.Runtime{} = rt)

    * `user_context` is **exactly** what the adapter's `setup/1` returned (no
      framework keys merged in).
    * `runtime` is this struct, carrying the per-command framework affordances.

  ## Fields

    * `:inject` - a 1-arity function; call `runtime.inject.(event)` to inject an
      event mid-execution. Injected events update projections immediately and are
      recorded with source `:injected` (DR-016).
    * `:start_poller` - a 1-arity function; call `runtime.start_poller.(opts)` to
      start a background resource poller (DR-018).
    * `:stutter` - `nil` on a normal execution; on a stutter/idempotency retry it
      is `%{attempt: pos_integer(), is_retry: true, idempotency_key: String.t() | nil}`.
      Prefer `PropertyDamage.Runtime.stuttering?/1` over matching the field directly.
    * `:mock_registry` - `nil` unless the run declared `mock_services:` (see
      `PropertyDamage.run/1`); otherwise the pid of the per-run
      `PropertyDamage.MockServiceRegistry`. An adapter that stands in for a SUT
      making an outbound call to a mocked third party reaches the mock through
      this handle (`get_handler_state/2` → the mock's `handle_request/2` →
      `push_events/3`); the framework flushes those events after the command
      (`source: :mock`).

  ## Example

      def execute(%CreateOrder{amount: amt}, %{client: client}, %Runtime{} = rt) do
        headers = if Runtime.stuttering?(rt), do: idempotency_headers(rt.stutter), else: []

        case HTTPClient.post(client, "/orders", %{amount: amt}, headers) do
          {:ok, %{status: 201, body: body}} ->
            {:ok, [%OrderCreated{order_id: body["id"], amount: amt}]}

          {:error, reason} ->
            {:error, reason}
        end
      end
  """

  @typedoc "Stutter context, present only on idempotency-retry executions."
  @type stutter ::
          %{
            attempt: pos_integer(),
            is_retry: boolean(),
            idempotency_key: String.t() | nil
          }
          | nil

  @type t :: %__MODULE__{
          inject: (struct() -> :ok),
          start_poller: (keyword() -> PropertyDamage.ResourcePoller.t()),
          stutter: stutter(),
          mock_registry: pid() | nil
        }

  @enforce_keys [:inject, :start_poller]
  defstruct [:inject, :start_poller, stutter: nil, mock_registry: nil]

  @doc """
  Returns `true` when this is a stutter/idempotency retry execution.

  Equivalent to checking that `runtime.stutter` is present, but keeps adapters
  from depending on the field shape. The first (non-retry) execution returns
  `false`.

  ## Examples

      iex> rt = %PropertyDamage.Runtime{inject: fn _ -> :ok end, start_poller: fn _ -> nil end}
      iex> PropertyDamage.Runtime.stuttering?(rt)
      false

      iex> rt = %PropertyDamage.Runtime{inject: fn _ -> :ok end, start_poller: fn _ -> nil end, stutter: %{attempt: 2, is_retry: true, idempotency_key: "k"}}
      iex> PropertyDamage.Runtime.stuttering?(rt)
      true
  """
  @spec stuttering?(t()) :: boolean()
  def stuttering?(%__MODULE__{stutter: nil}), do: false
  def stuttering?(%__MODULE__{}), do: true
end
