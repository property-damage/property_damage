defmodule PropertyDamage.Nemesis.ClockSkew do
  @moduledoc """
  Simulate clock skew and time anomalies.

  Provides a virtual clock that can be skewed forward or backward,
  useful for testing time-sensitive logic like TTLs, rate limiting,
  scheduling, and expiration handling.

  ## Configuration

  - `:skew_ms` - Amount to shift time by (positive = future, negative = past)
  - `:drift_rate` - Clock drift rate (1.0 = normal, 1.1 = 10% fast, 0.9 = 10% slow)
  - `:duration_ms` - How long the skew persists (default: 5000ms)
  - `:mode` - `:instant` (jump) or `:gradual` (drift)

  ## Virtual Clock

  This nemesis provides a virtual clock via `PropertyDamage.Nemesis.ClockSkew.now/0`.
  Your adapter should use this instead of `System.system_time/0` to be testable:

      defmodule MyAdapter do
        def get_current_time do
          PropertyDamage.Nemesis.ClockSkew.now()
        end
      end

  ## Example

      def commands do
        [
          {5, CreateSession},
          {5, CheckSessionExpiry},
          {1, PropertyDamage.Nemesis.ClockSkew}
        ]
      end

  ## Testing Behavior

  With clock skew, your system should:
  - Handle time going "backward" gracefully
  - Not break when time jumps forward
  - Tolerate clock drift between nodes
  """

  @behaviour PropertyDamage.Nemesis

  defstruct skew_ms: 0,
            drift_rate: 1.0,
            duration_ms: 5000,
            mode: :instant,
            injected_at: nil,
            real_time_at_injection: nil

  @modes [:instant, :gradual]

  # Process dictionary key for clock state
  @clock_key :nemesis_clock_skew

  # ============================================================================
  # Public API - Virtual Clock
  # ============================================================================

  @doc """
  Get the current virtual time.

  If clock skew is active, returns adjusted time. Otherwise returns real time.
  Use this in your adapter instead of `System.system_time/0`.
  """
  @spec now() :: integer()
  def now do
    case Process.get(@clock_key) do
      nil ->
        System.system_time(:millisecond)

      %{skew_ms: skew, drift_rate: rate, real_time_at_injection: base_real, mode: mode} ->
        real_now = System.system_time(:millisecond)

        case mode do
          :instant ->
            # Simple offset
            real_now + skew

          :gradual ->
            # Apply drift rate
            elapsed = real_now - base_real
            drifted_elapsed = round(elapsed * rate)
            base_real + drifted_elapsed + skew
        end
    end
  end

  @doc """
  Get the current skew configuration, if any.
  """
  @spec current_skew() :: map() | nil
  def current_skew do
    Process.get(@clock_key)
  end

  @doc """
  Check if clock skew is currently active.
  """
  @spec active?() :: boolean()
  def active? do
    Process.get(@clock_key) != nil
  end

  # ============================================================================
  # Nemesis Callbacks
  # ============================================================================

  @impl true
  def precondition(state) do
    not Map.has_key?(state[:active_faults] || %{}, :clock_skew)
  end

  @impl true
  def inject(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)
    real_time = System.system_time(:millisecond)

    # Set up virtual clock
    clock_state = %{
      skew_ms: command.skew_ms,
      drift_rate: command.drift_rate,
      mode: command.mode,
      real_time_at_injection: real_time
    }

    Process.put(@clock_key, clock_state)

    event = %{
      __struct__: ClockSkewInjected,
      skew_ms: command.skew_ms,
      drift_rate: command.drift_rate,
      mode: command.mode,
      injected_at: now
    }

    {:ok, [event]}
  end

  @impl true
  def restore(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    # Remove virtual clock
    Process.delete(@clock_key)

    event = %{
      __struct__: ClockSkewRestored,
      skew_ms: command.skew_ms,
      restored_at: now,
      duration_ms: now - (command.injected_at || now)
    }

    {:ok, [event]}
  end

  @impl true
  def new!(_state, overrides \\ %{}) do
    import StreamData

    # Generate skew: could be past (-) or future (+)
    bind(integer(-60_000..60_000), fn skew ->
      # Drift rate: 0.8 to 1.2 (20% slow to 20% fast)
      bind(float(min: 0.8, max: 1.2), fn drift ->
        bind(member_of(@modes), fn mode ->
          bind(integer(1000..10_000), fn duration ->
            constant(%__MODULE__{
              skew_ms: Map.get(overrides, :skew_ms, skew),
              drift_rate: Map.get(overrides, :drift_rate, Float.round(drift, 2)),
              mode: Map.get(overrides, :mode, mode),
              duration_ms: Map.get(overrides, :duration_ms, duration)
            })
          end)
        end)
      end)
    end)
  end

  @impl true
  def auto_restore?, do: true

  @impl true
  def duration_ms(%__MODULE__{duration_ms: d}), do: d
end

# Event structs
defmodule ClockSkewInjected do
  @moduledoc "Event emitted when clock skew is injected"
  defstruct [:skew_ms, :drift_rate, :mode, :injected_at]
end

defmodule ClockSkewRestored do
  @moduledoc "Event emitted when clock skew is restored"
  defstruct [:skew_ms, :restored_at, :duration_ms]
end
