defmodule PropertyDamage.Failure.CheckProjectionTest do
  # A check failure names the projection whose check failed, so a report can
  # say where the check lives even when two projections give their checks the
  # same name. The field is set on every path that runs a check, is nil for
  # the kinds that no check judges, and a saved report written before the
  # field existed loads with it nil.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, Failure, FailureReport, Persistence, Sequence}
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.ReferenceReport, as: R
  alias PropertyDamage.Test.ReportLayout, as: L
  alias PropertyDamage.Test.TmpPath

  alias __MODULE__.{AtStartupModel, AtTeardownModel, NeverModel, SharedNameModel}

  defmodule Bumped, do: defstruct([])

  defmodule Bump do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule BumpAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Bump{}, _ctx, _runtime), do: {:ok, [%Bumped{}]}
  end

  # A projection with one check on the settled state at the end of the run.
  defmodule AtTeardown do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{bumps: 0}

    @impl true
    def apply(state, %Bumped{}), do: %{state | bumps: state.bumps + 1}
    def apply(state, _), do: state

    @check at: :teardown
    def bumps_stay_low(state, _phase) do
      state.bumps < 1 or PropertyDamage.fail!("alice bumped", bumps: state.bumps)
    end
  end

  # A projection with one check on the initial state, before any command.
  defmodule AtStartup do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{ready: false}

    @impl true
    def apply(state, _), do: state

    @check at: :startup
    def ready_at_startup(state, _phase),
      do: state.ready or PropertyDamage.fail!("bob is not ready")
  end

  # A window that ends before its timeout: the predicate says "never".
  defmodule NeverConfirmed do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{bumps: 0}

    @impl true
    def apply(state, %Bumped{}), do: %{state | bumps: state.bumps + 1}
    def apply(state, _), do: state

    @eventually after: Bumped, timeout: {5, :seconds}, interval: {10, :milliseconds}
    def alice_is_confirmed(_state, %Bumped{}) do
      fn state ->
        if state.bumps > 0, do: {:fail, "alice was refused"}, else: false
      end
    end
  end

  # Two projections that give their checks the same name: the first holds, the
  # second fails.
  defmodule HoldsFirst do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: Bumped
    def balance_is_sane(_state, %Bumped{}), do: true
  end

  defmodule FailsSecond do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: Bumped
    def balance_is_sane(_state, %Bumped{}), do: PropertyDamage.fail!("bob has a negative balance")
  end

  for {name, sequence, checks} <- [
        {AtTeardownModel, AtTeardown, []},
        {AtStartupModel, AtStartup, []},
        {NeverModel, NeverConfirmed, []},
        {SharedNameModel, HoldsFirst, [FailsSecond]}
      ] do
    defmodule name do
      use PropertyDamage.Model

      @impl true
      def commands, do: [PropertyDamage.Failure.CheckProjectionTest.Bump]

      @impl true
      def command_sequence_projection, do: unquote(sequence)

      @impl true
      def check_projections, do: unquote(checks)
    end
  end

  # Loading a saved report decodes only atoms that exist, so every module is
  # loaded before a file is read.
  setup_all do
    Enum.each(Application.spec(:property_damage, :modules), &Code.ensure_loaded!/1)
    :ok
  end

  defp execute(model) do
    {:ok, queue} = PropertyDamage.EventQueue.start_link()

    try do
      {:ok, result} =
        Executor.run(Sequence.linear([%Bump{}]), model, BumpAdapter, event_queue: queue)

      result
    after
      PropertyDamage.EventQueue.stop(queue)
    end
  end

  defp run(model) do
    PropertyDamage.run(
      model: model,
      targets: [BumpAdapter],
      seed: 1,
      max_commands: 1,
      max_runs: 1,
      shrink: false,
      validate: false,
      replay_dir: false
    )
  end

  # The field is read with `Map.fetch!/2` (through `R.field/2`): a failure
  # without the field is an error, not a nil.
  defp projection(%Failure{type: %Failure.Check{} = check}), do: R.field(check, :projection)

  describe "a check that fails" do
    test "after a step names its projection" do
      report = L.report(:check_failed)

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :settled_amount}} =
               report.failure_reason

      assert projection(report.failure_reason) == Compare.Plain
    end

    test "an @eventually that times out names its projection" do
      report = L.report(:poll_timeout)

      assert %Failure{type: %Failure.Check{kind: :poll_timeout}} = report.failure_reason
      assert projection(report.failure_reason) == L.Eventual.Status
    end

    test "an @eventually that answers never names its projection" do
      result = execute(NeverModel)

      refute result.success

      assert %Failure{
               type: %Failure.Check{
                 kind: :check_failed,
                 name: :alice_is_confirmed,
                 context: context
               }
             } = result.failure_reason

      assert %{poll_count: _} = context
      assert projection(result.failure_reason) == NeverConfirmed
    end

    test "at teardown names its projection" do
      result = execute(AtTeardownModel)

      refute result.success

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :bumps_stay_low}} =
               result.failure_reason

      assert projection(result.failure_reason) == AtTeardown
    end

    test "at startup names its projection" do
      result = execute(AtStartupModel)

      refute result.success

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :ready_at_startup}} =
               result.failure_reason

      assert projection(result.failure_reason) == AtStartup
    end

    test "under check_mode: :record names its projection in the failure the report carries" do
      target = R.pay_target("a", %{at: %{1 => {:sync, -100}}})

      assert {:error, %FailureReport{} = report} =
               R.run(Compare.PlainModel, [target], check_mode: :record)

      assert report.check_mode == :record

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :settled_amount}} =
               report.failure_reason

      assert projection(report.failure_reason) == Compare.Plain
    end
  end

  describe "two projections that share a check name" do
    test "the failure names the projection whose check failed" do
      assert {:error, %FailureReport{} = report} = run(SharedNameModel)

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :balance_is_sane}} =
               report.failure_reason

      assert projection(report.failure_reason) == FailsSecond
    end

    test "the report names the second projection and not the first" do
      assert {:error, %FailureReport{} = report} = run(SharedNameModel)

      assert [%{value: value}] = L.fields_labeled(L.plain(report), "Projection")
      assert value == inspect(FailsSecond)
      refute value =~ "HoldsFirst"
    end
  end

  describe "a failure that no check judges" do
    test "check_failed/2 has no projection" do
      assert projection(Failure.check_failed(:x, "r")) == nil
    end

    test "check_failed/3 keeps the projection it is given" do
      assert projection(Failure.check_failed(:x, "r", MyApp.Ledger)) == MyApp.Ledger
    end

    test "an idempotency violation has no projection" do
      assert projection(Failure.idempotency_violation(%{command: :bump})) == nil
    end

    test "a linearization failure has no projection" do
      assert projection(Failure.linearization("no order explains the results")) == nil
    end

    test "a settle timeout has no projection" do
      assert projection(Failure.settle_timeout(:not_yet)) == nil
    end

    test "a projection violation has no projection, though its name is the projection" do
      failure = Failure.projection_violation(MyApp.Ledger, %RuntimeError{message: "bad event"})

      assert %Failure{type: %Failure.Check{name: MyApp.Ledger}} = failure
      assert projection(failure) == nil
    end

    test "a failure rebuilt from a check_failed signature has no projection" do
      assert projection(Failure.from_signature(:check_failed, :x)) == nil
    end

    test "a failure rebuilt from a poll_timeout signature has no projection" do
      assert projection(Failure.from_signature(:poll_timeout, :x)) == nil
    end
  end

  describe "a saved report" do
    @persistence Path.expand("../../support/fixtures/persistence", __DIR__)

    defp load(path) do
      case Persistence.load(path) do
        {:ok, report} -> report
        {:ok, report, _warnings} -> report
      end
    end

    # The two files were written at commit 83628d3, before a failure carried
    # its projection.
    for {kind, file, check} <- [
          {:check_failed, "v15_check_failed_without_projection.pd", :settled_amount},
          {:poll_timeout, "v15_poll_timeout_without_projection.pd", :payment_eventually_confirmed}
        ] do
      test "written before the field existed loads with a nil projection (#{kind})" do
        report = load(Path.join(@persistence, unquote(file)))

        assert %Failure{type: %Failure.Check{kind: unquote(kind), name: unquote(check)} = check} =
                 report.failure_reason

        assert Map.has_key?(check, :projection)
        assert R.field(check, :projection) == nil
      end

      test "written before the field existed renders without a Projection line (#{kind})" do
        report = load(Path.join(@persistence, unquote(file)))

        assert L.fields_labeled(L.plain(report), "Check") != []
        assert L.fields_labeled(L.plain(report), "Projection") == []
      end
    end

    test "round-trips the projection of a failure saved now" do
      report = L.report(:check_failed)
      saved = projection(report.failure_reason)
      assert saved == Compare.Plain

      dir = TmpPath.unique("pd_check_projection")
      on_exit(fn -> File.rm_rf(dir) end)
      assert {:ok, path} = Persistence.save(report, dir)

      assert projection(load(path).failure_reason) == saved
    end
  end
end
