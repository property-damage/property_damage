defmodule PropertyDamage.SurvivorFinalizeFailureTest do
  # When a run goes on after a non-reference target was retired, a failure a
  # remaining target reports while it finalizes its run (an `@eventually`
  # timeout, a `:teardown` check) is one of the run's failures like any
  # other: it competes for primary in root order, then target order, and is
  # listed in `other_failures` otherwise. A finalize failure that belongs to
  # no root happened at the end of the run, after every failure at a root.
  use ExUnit.Case, async: true

  alias PropertyDamage.Failure
  alias PropertyDamage.Test.{ActiveSet, Compare, VariantSupport}
  alias PropertyDamage.Test.ActiveSet.Booked

  defmodule Observed do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{booked: 0}

    @impl true
    def apply(s, %Booked{}), do: %{s | booked: s.booked + 1}
    def apply(s, _), do: s

    @compare every: 1
    def booked(s, _root), do: s.booked
  end

  defmodule Settles do
    @moduledoc false
    # The window opened by the reference's first booking never closes.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(s, _), do: s

    @eventually after: Booked, timeout: {100, :milliseconds}, interval: {10, :milliseconds}
    def settles(_s, %Booked{n: n, by: by}), do: fn _s -> not (by == "a" and n == 0) end
  end

  setup_all do
    watch =
      ActiveSet.define_model!(Module.concat(__MODULE__, WatchModel), [Observed, ActiveSet.Watch])

    eventual =
      ActiveSet.define_model!(Module.concat(__MODULE__, EventualModel), [Observed, Settles])

    {:ok, watch: watch, eventual: eventual}
  end

  setup do
    {:ok, recorder: VariantSupport.start_recorder()}
  end

  defp t(ctx, name, config \\ %{}), do: ActiveSet.target(name, ctx.recorder, config)

  defp summary(entry) do
    %Failure{} = failure = Map.fetch!(entry, :failure)
    {Map.fetch!(entry, :variant), Map.fetch!(entry, :root), Failure.kind(failure)}
  end

  test "the reference's :teardown check failure is listed after a retirement's failure", ctx do
    targets = [
      t(ctx, "a", %{fail_teardown: true}),
      t(ctx, "b"),
      t(ctx, "c", %{fail: %{1 => :error}})
    ]

    assert {:error, report} = Compare.run(ctx.watch, targets, max_commands: 5)
    assert report.kind == :execution_failed
    assert report.variant == %{index: 2, name: "c"}
    assert report.failed_at_index == 1

    assert [entry] = Compare.field(report, :other_failures)
    assert summary(entry) == {%{index: 0, name: "a"}, nil, :check_failed}
    assert Failure.name(Map.fetch!(entry, :failure)) == :torn_down_cleanly
  end

  test "the reference's @eventually timeout at root 0 is primary over a retirement at root 3",
       ctx do
    targets = [t(ctx, "a"), t(ctx, "b"), t(ctx, "c", %{fail: %{3 => :error}})]

    assert {:error, report} = Compare.run(ctx.eventual, targets, max_commands: 5)
    assert report.kind == :check_failed
    assert report.variant == %{index: 0, name: "a"}
    assert report.failed_at_index == 0
    assert Failure.kind(report.failure_reason) == :poll_timeout

    assert Enum.map(Compare.field(report, :other_failures), &summary/1) == [
             {%{index: 2, name: "c"}, 3, :adapter_error}
           ]
  end
end
