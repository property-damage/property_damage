defmodule PropertyDamage.MintRunTest do
  @moduledoc """
  DR-034 run-level guarantees for `mint_per_run`: the nonce default is drawn
  from crypto entropy (never the process RNG, which ExUnit pins under
  `--seed N`), and each SUT execution within a logical run (shrink attempts,
  the reproduction re-execution) draws a distinct `mint_epoch`.
  """
  use ExUnit.Case, async: false

  defmodule Send do
    @behaviour PropertyDamage.Command
    defstruct [:request_id]
    @impl true
    def generator(_overrides) do
      StreamData.constant(%{request_id: PropertyDamage.mint_per_run(:uuid)})
    end
  end

  defmodule Proj do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}
    @impl true
    def apply(state, %Send{}), do: %{state | count: state.count + 1}
    def apply(state, _), do: state

    # Always fails once a command has run, so the run fails and shrinks.
    @trigger every: 1
    def always_fails(state, _cmd_or_event) do
      if state.count >= 1, do: PropertyDamage.fail!("boom", count: state.count)
    end
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def commands, do: [Send]
    @impl true
    def command_sequence_projection, do: Proj
    @impl true
    def assertion_projections, do: [Proj]
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(_c, _s), do: []
  end

  # A non-resetting SUT: every execution records the request_ids it received to
  # a recorder Agent supplied via adapter_config, which persists across the
  # run's many executions (exploration, shrink attempts, reproduction).
  defmodule RecordingAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Send{request_id: rid}, %{recorder: rec}, _runtime) do
      Agent.update(rec, &[rid | &1])
      {:ok, []}
    end
  end

  test "the nonce default is not drawn from the process RNG" do
    # Pin :rand identically before each run. A :rand-based nonce default would be
    # pinned to the same value (RED); the crypto default differs (GREEN).
    :rand.seed(:exsss, 999)

    {:error, r1} =
      PropertyDamage.run(
        model: Model,
        adapter: no_op_adapter(),
        seed: 12_345,
        max_runs: 1,
        shrink: false
      )

    :rand.seed(:exsss, 999)

    {:error, r2} =
      PropertyDamage.run(
        model: Model,
        adapter: no_op_adapter(),
        seed: 12_345,
        max_runs: 1,
        shrink: false
      )

    assert is_integer(r1.trace.run_nonce)
    refute r1.trace.run_nonce == r2.trace.run_nonce
  end

  test "PD_RUN_NONCE / an explicit nonce are recorded on the report" do
    {:error, report} =
      PropertyDamage.run(
        model: Model,
        adapter: no_op_adapter(),
        seed: 12_345,
        run_nonce: 7_777_777,
        max_runs: 1,
        shrink: false
      )

    assert report.trace.run_nonce == 7_777_777
    # The report's trace describes the reproduction re-execution, which draws a
    # fresh (non-exploration) epoch (DR-034); pinning (nonce, epoch) reproduces
    # it byte-exactly.
    assert is_integer(report.trace.mint_epoch) and report.trace.mint_epoch >= 1
  end

  test "shrink attempts and the reproduction each draw a distinct mint epoch" do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    {:error, _report} =
      PropertyDamage.run(
        model: Model,
        adapter: RecordingAdapter,
        adapter_config: %{recorder: recorder},
        seed: 12_345,
        run_nonce: 555,
        max_runs: 1,
        shrink: true
      )

    recorded = Agent.get(recorder, & &1)

    # The SUT received minted ids across many executions (exploration + shrink
    # attempts + reproduction). With a distinct epoch per execution and one
    # position per command, every id sent is unique: no two executions collided.
    assert length(recorded) > 1
    assert length(recorded) == length(Enum.uniq(recorded))
  end

  # A no-op adapter (execution records nothing); the run still fails via the
  # always-failing invariant.
  defp no_op_adapter do
    PropertyDamage.MintRunTest.NoOpAdapter
  end

  defmodule NoOpAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Send{}, _ctx, _runtime), do: {:ok, []}
  end
end
