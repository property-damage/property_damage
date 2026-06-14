defmodule PropertyDamage.Nemesis.CertificateExpiry do
  @moduledoc """
  Simulate TLS/SSL certificate expiry and validation failures.

  Tests how your system handles certificate-related failures, useful for
  verifying certificate rotation, expiry handling, and TLS error recovery.

  ## Configuration

  - `:failure_type` - Type of certificate failure to simulate:
    - `:expired` - Certificate has expired
    - `:not_yet_valid` - Certificate not yet valid (future start date)
    - `:wrong_host` - Certificate hostname mismatch
    - `:self_signed` - Untrusted self-signed certificate
    - `:revoked` - Certificate has been revoked
  - `:duration_ms` - How long the failure persists (default: 5000ms)
  - `:target` - Specific service/endpoint to affect (default: `:all`)

  ## Usage

  This nemesis sets a flag that your adapter should check when making TLS connections:

      defmodule MyAdapter do
        alias PropertyDamage.Nemesis.CertificateExpiry

        def connect(host, port) do
          if CertificateExpiry.should_fail?() do
            {:error, CertificateExpiry.get_failure()}
          else
            :ssl.connect(host, port, opts)
          end
        end
      end

  ## Example

      def commands do
        [
          {5, SecureAPICall},
          {1, PropertyDamage.Nemesis.CertificateExpiry}
        ]
      end

  ## Testing Behavior

  With certificate failures, your system should:
  - Detect and report the specific certificate error
  - Not proceed with insecure connections
  - Retry with backoff for transient issues
  - Alert operators for persistent failures
  """

  @behaviour PropertyDamage.Nemesis

  defstruct failure_type: :expired,
            duration_ms: 5000,
            target: :all,
            injected_at: nil

  @failure_types [:expired, :not_yet_valid, :wrong_host, :self_signed, :revoked]

  # Process dictionary key for certificate failure state
  @cert_key :nemesis_certificate_failure

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Check if certificate failure should be simulated.
  """
  @spec should_fail?(atom()) :: boolean()
  def should_fail?(target \\ :all) do
    case Process.get(@cert_key) do
      nil ->
        false

      %{target: :all} ->
        true

      %{target: configured_target} ->
        target == :all or target == configured_target
    end
  end

  @doc """
  Get the current certificate failure configuration.

  Returns a map with `:failure_type` and `:error` that can be used
  to simulate the appropriate TLS error.
  """
  @spec get_failure() :: map() | nil
  def get_failure do
    case Process.get(@cert_key) do
      nil ->
        nil

      %{failure_type: type} = config ->
        Map.put(config, :error, failure_to_error(type))
    end
  end

  @doc """
  Get the SSL/TLS error tuple for the current failure type.

  Useful for returning realistic error tuples from mocked connections.
  """
  @spec get_ssl_error() :: {:error, term()} | nil
  def get_ssl_error do
    case get_failure() do
      nil -> nil
      %{error: error} -> {:error, error}
    end
  end

  @doc """
  Check if certificate failure simulation is currently active.
  """
  @spec active?() :: boolean()
  def active? do
    Process.get(@cert_key) != nil
  end

  @doc """
  Get a human-readable description of the current failure.
  """
  @spec failure_description() :: String.t() | nil
  def failure_description do
    case Process.get(@cert_key) do
      nil -> nil
      %{failure_type: type} -> describe_failure(type)
    end
  end

  # ============================================================================
  # Nemesis Callbacks
  # ============================================================================

  @impl true
  def precondition(state) do
    not Map.has_key?(state[:active_faults] || %{}, :certificate_expiry)
  end

  @impl true
  def inject(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    # Set up certificate failure simulation
    cert_config = %{
      failure_type: command.failure_type,
      target: command.target,
      injected_at: now
    }

    Process.put(@cert_key, cert_config)

    event = %{
      __struct__: CertificateFailureInjected,
      failure_type: command.failure_type,
      target: command.target,
      description: describe_failure(command.failure_type),
      injected_at: now
    }

    {:ok, [event]}
  end

  @impl true
  def restore(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    # Remove certificate failure simulation
    Process.delete(@cert_key)

    event = %{
      __struct__: CertificateFailureRestored,
      failure_type: command.failure_type,
      target: command.target,
      restored_at: now,
      duration_ms: now - (command.injected_at || now)
    }

    {:ok, [event]}
  end

  @impl true
  def new!(_state, overrides \\ %{}) do
    import StreamData

    bind(member_of(@failure_types), fn failure_type ->
      bind(integer(1000..15_000), fn duration ->
        constant(%__MODULE__{
          failure_type: Map.get(overrides, :failure_type, failure_type),
          duration_ms: Map.get(overrides, :duration_ms, duration),
          target: Map.get(overrides, :target, :all)
        })
      end)
    end)
  end

  @impl true
  def auto_restore?, do: true

  @impl true
  def duration_ms(%__MODULE__{duration_ms: d}), do: d

  # ============================================================================
  # Error Mapping
  # ============================================================================

  defp failure_to_error(:expired) do
    {:tls_alert, {:certificate_expired, ~c"certificate has expired"}}
  end

  defp failure_to_error(:not_yet_valid) do
    {:tls_alert, {:certificate_not_yet_valid, ~c"certificate is not yet valid"}}
  end

  defp failure_to_error(:wrong_host) do
    {:tls_alert, {:handshake_failure, ~c"hostname mismatch"}}
  end

  defp failure_to_error(:self_signed) do
    {:tls_alert, {:unknown_ca, ~c"self-signed certificate"}}
  end

  defp failure_to_error(:revoked) do
    {:tls_alert, {:certificate_revoked, ~c"certificate has been revoked"}}
  end

  defp describe_failure(:expired), do: "Certificate has expired"
  defp describe_failure(:not_yet_valid), do: "Certificate is not yet valid"
  defp describe_failure(:wrong_host), do: "Certificate hostname mismatch"
  defp describe_failure(:self_signed), do: "Self-signed certificate (untrusted CA)"
  defp describe_failure(:revoked), do: "Certificate has been revoked"
end

# Event structs
defmodule CertificateFailureInjected do
  @moduledoc "Event emitted when certificate failure is injected"
  defstruct [:failure_type, :target, :description, :injected_at]
end

defmodule CertificateFailureRestored do
  @moduledoc "Event emitted when certificate failure is restored"
  defstruct [:failure_type, :target, :restored_at, :duration_ms]
end
