defmodule PropertyDamage.ExecutionFailureActiveSetTest do
  # An adapter error at a root is a failure in every mode, never an
  # observation. A failure in the reference ends the run. A failure in another
  # variant stops that variant alone: it is finalized and torn down at once,
  # and the others run on while at least one non-reference variant remains.
  use ExUnit.Case, async: true

  alias PropertyDamage.Failure
  alias PropertyDamage.Test.{ActiveSet, Compare, VariantSupport}

  @ns inspect(__MODULE__)

  @sources %{
    observed: """
    defmodule #{@ns}.Observed do
      use PropertyDamage.Model.Projection
      alias PropertyDamage.Test.ActiveSet
      alias PropertyDamage.Test.ActiveSet.Booked

      @impl true
      def init, do: %{by: nil, sink: nil, booked: 0}

      @impl true
      def apply(s, %Booked{by: by, sink: sink}), do: %{s | by: by, sink: sink, booked: s.booked + 1}
      def apply(s, _), do: s

      @compare every: 1
      def booked(s, root), do: ActiveSet.observed(s, root, s.booked)
    end
    """
  }

  setup_all do
    compiled = Compare.compile_all(@sources)

    model =
      ActiveSet.define_model!(Module.concat(__MODULE__, Model), [
        Module.concat(__MODULE__, Observed),
        ActiveSet.Watch
      ])

    {:ok, compiled: compiled, model: model}
  end

  setup ctx do
    Compare.fixture!(ctx.compiled, :observed)
    {:ok, recorder: VariantSupport.start_recorder()}
  end

  defp run(ctx, targets, extra) do
    Compare.run(ctx.model, targets, Keyword.merge([max_commands: 5], extra))
  end

  defp t(ctx, name, config \\ %{}), do: ActiveSet.target(name, ctx.recorder, config)

  describe "an adapter error at a root" do
    test "is :execution_failed in the reference even when every target answers the same error",
         ctx do
      targets = [t(ctx, "a", %{fail: %{1 => :error}}), t(ctx, "b", %{fail: %{1 => :error}})]

      assert {:error, report} = run(ctx, targets, [])
      assert report.kind == :execution_failed
      assert report.variant == %{index: 0, name: "a"}
      assert report.failed_at_index == 1

      # An error answer keeps its reason and has no stacktrace.
      assert Failure.kind(report.failure_reason) == :adapter_error
      assert Failure.detail(report.failure_reason) == {:refused, 1}
      assert report.stacktrace == nil
    end

    test "an adapter raise is the same kind and keeps the exception and its stacktrace apart",
         ctx do
      targets = [t(ctx, "a", %{fail: %{1 => :raise}}), t(ctx, "b")]

      assert {:error, report} = run(ctx, targets, [])
      assert report.kind == :execution_failed
      assert report.variant == %{index: 0, name: "a"}
      assert report.failed_at_index == 1

      assert Failure.kind(report.failure_reason) == :adapter_error
      assert %RuntimeError{message: "book 1 exploded"} = Failure.detail(report.failure_reason)
      assert [_ | _] = report.stacktrace

      # Told apart from an error answer by the detail and the stacktrace.
      refute Failure.detail(report.failure_reason) == {:refused, 1}
    end
  end

  describe "a failure in the reference" do
    test "stops the run: no later root, every variant torn down, no comparison at that root",
         ctx do
      targets = [t(ctx, "a", %{fail: %{1 => :error}}), t(ctx, "b"), t(ctx, "c")]

      assert {:error, report} = run(ctx, targets, [])
      assert report.variant == %{index: 0, name: "a"}

      entries = ActiveSet.first_run(ctx.recorder)

      for name <- ["a", "b", "c"] do
        assert Enum.all?(ActiveSet.executed(entries, name), &(&1 <= 1))
        assert Enum.count(entries, &(&1 == {:teardown, name})) == 1
        refute 1 in ActiveSet.compared(entries, name)
      end
    end
  end

  describe "a failure in a non-reference variant" do
    test "finalizes and tears down that variant before the next root, and the others run on",
         ctx do
      targets = [t(ctx, "a"), t(ctx, "b"), t(ctx, "c", %{fail: %{2 => :error}})]

      assert {:error, report} = run(ctx, targets, [])
      assert report.kind == :execution_failed
      assert report.variant == %{index: 2, name: "c"}
      assert report.failed_at_index == 2

      entries = ActiveSet.first_run(ctx.recorder)

      # The survivors execute every later root; "c" executes none.
      assert ActiveSet.executed(entries, "a") == [0, 1, 2, 3, 4]
      assert ActiveSet.executed(entries, "b") == [0, 1, 2, 3, 4]
      assert Enum.all?(ActiveSet.executed(entries, "c"), &(&1 <= 2))

      # "c"'s :teardown check, then its adapter teardown, then root 3 anywhere.
      check = ActiveSet.position(entries, &(&1 == {:teardown_check, "c"}))
      teardown = ActiveSet.position(entries, &(&1 == {:teardown, "c"}))
      next_root = ActiveSet.position(entries, &match?({:executed, _, 3}, &1))

      assert is_integer(check) and is_integer(teardown) and is_integer(next_root)
      assert check < teardown
      assert teardown < next_root
      assert Enum.count(entries, &(&1 == {:teardown, "c"})) == 1

      # From root 2 on, only the survivors are compared.
      assert Enum.all?(ActiveSet.compared(entries, "c"), &(&1 < 2))
      assert 4 in ActiveSet.compared(entries, "b")
    end

    test "with two targets, the run ends right after that variant's teardown", ctx do
      targets = [t(ctx, "a"), t(ctx, "b", %{fail: %{1 => :error}})]

      assert {:error, report} = run(ctx, targets, [])
      assert report.kind == :execution_failed
      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == 1

      entries = ActiveSet.first_run(ctx.recorder)
      assert Enum.all?(ActiveSet.executed(entries, "a"), &(&1 <= 1))
      assert Enum.count(entries, &(&1 == {:teardown, "a"})) == 1
      assert Enum.count(entries, &(&1 == {:teardown, "b"})) == 1
    end

    test "under :parallel the failed variant stops and the others run to the end", ctx do
      targets = [t(ctx, "a"), t(ctx, "b"), t(ctx, "c", %{fail: %{2 => :error}})]

      assert {:error, report} = run(ctx, targets, concurrency: :parallel)
      assert report.variant == %{index: 2, name: "c"}
      assert report.failed_at_index == 2

      entries = ActiveSet.first_run(ctx.recorder)
      assert Enum.sort(ActiveSet.executed(entries, "a")) == [0, 1, 2, 3, 4]
      assert Enum.sort(ActiveSet.executed(entries, "b")) == [0, 1, 2, 3, 4]
      assert Enum.all?(ActiveSet.executed(entries, "c"), &(&1 <= 2))
      assert Enum.all?(ActiveSet.compared(entries, "c"), &(&1 < 2))
    end
  end
end
