defmodule PropertyDamage.CommandSpecSurfaceTest do
  @moduledoc """
  DR-028 (served/servant clean break, P6): `command_spec/1` is the single static
  metadata surface. Every servant read of static command metadata routes through
  the resolved spec map, not through scattered `function_exported?/3` probes of
  per-callback functions (`semantics/0`, `settle_config/0`, `idempotent?/0`, ...).

  These are failing-first behaviour-preservation tests: each declares a fact ONLY
  via `command_spec/1` (never the legacy callback) and asserts the framework
  honours it. Before P6 the reads still probed the deleted callbacks, so each test
  is RED on HEAD.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{Executor, Sequence, Settle}

  # --- Commands declaring metadata ONLY via command_spec -----------------------

  defmodule AsyncViaSpec do
    @moduledoc false
    use PropertyDamage.Command,
      execution: :async,
      settle: %{timeout_ms: 1234, interval_ms: 56, backoff: :exponential}

    defstruct [:id]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule NonIdempotentViaSpec do
    @moduledoc false
    # Declares non-idempotency ONLY through the spec (no idempotent?/0).
    use PropertyDamage.Command, idempotent: false

    defstruct [:id]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule AcceptableRetryViaSpec do
    @moduledoc false
    # A retry answers another event type than the first execution.
    use PropertyDamage.Command

    defmodule Created, do: defstruct([:id])
    defmodule AlreadyExists, do: defstruct([:id])

    defstruct [:id]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  # --- Settle seam: get_semantics / get_config resolve via command_spec --------

  describe "Settle resolution via command_spec (RED on HEAD)" do
    test "get_semantics/1 reads :execution from command_spec for a module" do
      assert Settle.get_semantics(AsyncViaSpec) == :async
    end

    test "get_semantics/1 reads :execution from command_spec for a struct" do
      assert Settle.get_semantics(%AsyncViaSpec{id: 1}) == :async
    end

    test "requires_settling?/1 is true for an async-via-spec command" do
      assert Settle.requires_settling?(%AsyncViaSpec{id: 1})
    end

    test "get_config/1 reads :settle from command_spec" do
      config = Settle.get_config(%AsyncViaSpec{id: 1})
      assert config.timeout_ms == 1234
      assert config.interval_ms == 56
      assert config.backoff == :exponential
    end
  end

  # --- Stutter seam: idempotent via command_spec, retry agreement via using: ---

  defmodule PassthroughProjection do
    @moduledoc false
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _event), do: state
  end

  defmodule IdempotentModel do
    @moduledoc false
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [NonIdempotentViaSpec]
    @impl true
    def command_sequence_projection, do: PassthroughProjection
  end

  defmodule NonIdempotentAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    defmodule Charged, do: defstruct([:id, :attempt])

    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_context), do: :ok

    # Non-idempotent: tag with attempt number so a stutter retry's events differ
    # from the first execution's.
    @impl true
    def execute(%NonIdempotentViaSpec{id: id}, _ctx, runtime) do
      attempt =
        if PropertyDamage.Runtime.stuttering?(runtime), do: runtime.stutter.attempt, else: 1

      {:ok, [%Charged{id: id, attempt: attempt}]}
    end
  end

  @always_stutter %PropertyDamage.Stutter.Config{
    probability: 1.0,
    max_repeats: 1,
    delay_ms: 0,
    commands: :all,
    enabled: true
  }

  test "idempotent: false via command_spec excludes a command from stutter (RED on HEAD)" do
    {:ok, result} =
      Executor.run(
        Sequence.linear([%NonIdempotentViaSpec{id: "x"}]),
        IdempotentModel,
        NonIdempotentAdapter,
        stutter_config: @always_stutter,
        rng_seed: 7
      )

    # Because the command is declared non-idempotent via the spec, it must NOT be
    # stuttered, so no idempotency violation can be raised: the run succeeds.
    assert result.success, "expected non-idempotent-via-spec command to be skipped by stutter"
  end

  defmodule AcceptableModel do
    @moduledoc false
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [AcceptableRetryViaSpec]
    @impl true
    def command_sequence_projection, do: PassthroughProjection
  end

  defmodule AcceptableAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_context), do: :ok

    # First execution returns Created; a stutter retry returns AlreadyExists,
    # which the stutter `using:` predicate accepts.
    @impl true
    def execute(%AcceptableRetryViaSpec{id: id}, _ctx, runtime) do
      if PropertyDamage.Runtime.stuttering?(runtime) do
        {:ok, [%AcceptableRetryViaSpec.AlreadyExists{id: id}]}
      else
        {:ok, [%AcceptableRetryViaSpec.Created{id: id}]}
      end
    end
  end

  @acceptable_stutter %PropertyDamage.Stutter.Config{
    probability: 1.0,
    max_repeats: 1,
    delay_ms: 0,
    commands: :all,
    enabled: true,
    using: &__MODULE__.created_or_already_exists/2
  }

  @doc false
  # Agrees when every retry event is the original's Created or an AlreadyExists
  # for the same id.
  def created_or_already_exists([%{id: id}] = original, retry) do
    retry == original or retry == [%AcceptableRetryViaSpec.AlreadyExists{id: id}]
  end

  test "a stutter using: predicate accepts an alternative retry answer" do
    {:ok, result} =
      Executor.run(
        Sequence.linear([%AcceptableRetryViaSpec{id: "x"}]),
        AcceptableModel,
        AcceptableAdapter,
        stutter_config: @acceptable_stutter,
        rng_seed: 7
      )

    # The retry returns a different event type, but the using: predicate
    # accepts it, so the comparison matches and the run succeeds.
    assert result.success, "expected the stutter using: predicate to accept the retry"
  end
end
