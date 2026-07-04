defmodule PropertyDamage.StutterShrinkTest do
  @moduledoc """
  P4 (DR-029 "Explicit RNG"): stutter draws come from an explicit per-run RNG
  threaded through `%Executor.State{}` and reproduced by the shrinker.

  Two load-bearing properties:

    1. **Shrinkable stutter** (Scope B): a stutter-induced idempotency violation
       shrinks to its minimal reproduction. Before P4 stutter failures were
       excluded from shrinking entirely (the shrinker re-ran without stutter, so
       no candidate reproduced the violation), so the "shrunk" sequence was the
       full original. After P4 the shrinker forces stutter during reproduction
       and minimizes to the single offending command.

    2. **Self-consistent determinism**: the same seed reproduces the same stutter
       decisions / event log / result. This is a *property* (same seed -> same
       behavior), NOT byte-identical equality to the prior global-`:rand` stream.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{Executor, Failure, Sequence, Shrinker}
  alias PropertyDamage.Stutter.Config

  # --- Commands ---------------------------------------------------------------

  defmodule Noop do
    defstruct [:id]
  end

  defmodule Charge do
    # Non-idempotent under stutter: a retry yields a different event than the
    # first execution (see Adapter), tripping :strict comparison.
    defstruct [:id]
  end

  # --- Events -----------------------------------------------------------------

  defmodule NoopDone do
    defstruct [:id]
  end

  defmodule Charged do
    defstruct [:id, :attempt]
  end

  # --- Projection / Model -----------------------------------------------------

  defmodule Projection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _event), do: state
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Noop, Charge]
    @impl true
    def command_sequence_projection, do: Projection
  end

  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Noop{id: id}, _context, _runtime) do
      {:ok, [%NoopDone{id: id}]}
    end

    # Non-idempotent: tag the event with the attempt number. The first execution
    # is attempt 1; a stutter retry carries attempt >= 2 in its Runtime context,
    # so retry events differ from the original under :strict comparison.
    def execute(%Charge{id: id}, _context, runtime) do
      attempt =
        if PropertyDamage.Runtime.stuttering?(runtime) do
          runtime.stutter.attempt
        else
          1
        end

      {:ok, [%Charged{id: id, attempt: attempt}]}
    end
  end

  @stutter %Config{
    probability: 1.0,
    max_repeats: 1,
    delay_ms: 0,
    commands: [Charge],
    comparison: :strict,
    enabled: true
  }

  defp run_sequence(commands, rng_seed) do
    sequence = Sequence.linear(commands)

    {:ok, result} =
      Executor.run(sequence, Model, Adapter,
        stutter_config: @stutter,
        rng_seed: rng_seed
      )

    result
  end

  test "a stutter idempotency violation shrinks to its minimal reproduction" do
    rng_seed = 12_345

    commands = [
      %Noop{id: "a"},
      %Noop{id: "b"},
      %Noop{id: "c"},
      %Charge{id: "p1"}
    ]

    result = run_sequence(commands, rng_seed)

    # Sanity: the original sequence fails with an idempotency violation at the
    # Charge index.
    refute result.success

    assert %Failure{type: %Failure.Assertion{kind: :idempotency_violation}} =
             result.failure_reason

    assert result.failed_at_index == 3

    shrink_result =
      Shrinker.shrink(Sequence.linear(commands),
        failed_at_index: result.failed_at_index,
        failure_reason: result.failure_reason,
        model: Model,
        adapter: Adapter,
        stutter_config: @stutter,
        rng_seed: rng_seed
      )

    shrunk = Sequence.to_list(shrink_result.sequence)

    # The three idempotent Noops are irrelevant to the violation; the minimal
    # reproduction is the single non-idempotent Charge.
    assert length(shrunk) == 1
    assert [%Charge{}] = shrunk
  end

  test "same seed reproduces the same stutter outcome (self-consistent determinism)" do
    commands = [%Charge{id: "p1"}]

    a = run_sequence(commands, 999)
    b = run_sequence(commands, 999)

    assert a.success == b.success
    assert a.failure_reason == b.failure_reason
    assert a.failed_at_index == b.failed_at_index
  end
end
