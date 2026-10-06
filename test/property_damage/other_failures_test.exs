defmodule PropertyDamage.OtherFailuresTest do
  # When several variants fail in one run, the report's primary failure is the
  # first in root order, then target order; the others are listed in
  # `other_failures`. Only the primary failure is shrunk, and the list
  # persists with the report.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Persistence, Sequence}
  alias PropertyDamage.Test.{ActiveSet, Compare, VariantSupport}
  alias PropertyDamage.Test.ActiveSet.Book

  @ns inspect(__MODULE__)

  @sources %{
    observed: """
    defmodule #{@ns}.Observed do
      use PropertyDamage.Model.Projection
      alias PropertyDamage.Test.ActiveSet.Booked

      @impl true
      def init, do: %{booked: 0}

      @impl true
      def apply(s, %Booked{}), do: %{s | booked: s.booked + 1}
      def apply(s, _), do: s

      @compare every: 1
      def booked(s, _root), do: s.booked
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

  defp others(report), do: Compare.field(report, :other_failures)

  defp summary(entry) do
    %Failure{} = failure = Map.fetch!(entry, :failure)
    {Map.fetch!(entry, :variant), Map.fetch!(entry, :root), Failure.kind(failure)}
  end

  describe "the primary failure" do
    test "is the first in root order: a later failure of another variant is listed after it",
         ctx do
      targets = [
        t(ctx, "a"),
        t(ctx, "b", %{fail: %{4 => :error}}),
        t(ctx, "c", %{fail: %{2 => :error}})
      ]

      assert {:error, report} = run(ctx, targets, [])
      assert report.variant == %{index: 2, name: "c"}
      assert report.failed_at_index == 2

      assert Enum.map(others(report), &summary/1) == [
               {%{index: 1, name: "b"}, 4, :adapter_error}
             ]
    end

    test "is first in target order among failures at one root", ctx do
      targets = [
        t(ctx, "a"),
        t(ctx, "b", %{fail: %{3 => :error}}),
        t(ctx, "c", %{fail: %{3 => :error}})
      ]

      assert {:error, report} = run(ctx, targets, [])
      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == 3

      assert Enum.map(others(report), &summary/1) == [
               {%{index: 2, name: "c"}, 3, :adapter_error}
             ]
    end

    test "a :teardown check failing in the early teardown of a failed variant is never primary",
         ctx do
      targets = [
        t(ctx, "a"),
        t(ctx, "b"),
        t(ctx, "c", %{fail: %{1 => :error}, fail_teardown: true})
      ]

      assert {:error, report} = run(ctx, targets, [])
      assert report.kind == :execution_failed
      assert report.variant == %{index: 2, name: "c"}
      assert report.failed_at_index == 1

      assert [entry] = others(report)
      assert Map.fetch!(entry, :variant) == %{index: 2, name: "c"}
      assert %Failure{} = failure = Map.fetch!(entry, :failure)
      assert Failure.kind(failure) == :check_failed
      assert Failure.name(failure) == :torn_down_cleanly
    end

    test "a run with one failure has no other failures", ctx do
      targets = [t(ctx, "a"), t(ctx, "b", %{fail: %{2 => :error}})]

      assert {:error, report} = run(ctx, targets, [])
      assert others(report) == []
    end
  end

  describe "shrinking" do
    test "accepts a candidate whose other failures differ from the original's", ctx do
      # "c" fails at root 5 and then "b" at root 6.
      targets = [
        t(ctx, "a"),
        t(ctx, "b", %{fail: %{6 => :error}}),
        t(ctx, "c", %{fail: %{5 => :error}})
      ]

      assert {:error, unshrunk} = run(ctx, targets, max_commands: 8)
      assert unshrunk.variant == %{index: 2, name: "c"}
      assert [_] = others(unshrunk)

      assert {:error, shrunk} = run(ctx, targets, max_commands: 8, shrink: true)
      assert shrunk.variant == %{index: 2, name: "c"}
      assert shrunk.kind == :execution_failed
      assert shrunk.failed_at_index <= 5
      assert length(others(shrunk)) < length(others(unshrunk))
    end

    test "rejects a candidate whose primary failure moved to another variant", ctx do
      # "b" fails at the command numbered 4 when 3 ran before it. "c" fails at
      # the command numbered 2 unless 0 ran before it, so every candidate
      # that drops 0 but keeps 2 moves the primary failure to "c".
      targets = [
        t(ctx, "a"),
        t(ctx, "b", %{fail_after: %{4 => 3}}),
        t(ctx, "c", %{fail_unless: %{2 => 0}})
      ]

      assert {:error, unshrunk} = run(ctx, targets, max_commands: 8)
      assert unshrunk.variant == %{index: 1, name: "b"}
      assert unshrunk.failed_at_index == 4

      assert {:error, shrunk} = run(ctx, targets, max_commands: 8, shrink: true)
      assert shrunk.variant == %{index: 1, name: "b"}
      assert shrunk.kind == :execution_failed

      numbers = for %Book{n: n} <- Sequence.to_list(FailureReport.shrunk_sequence(shrunk)), do: n
      assert 3 in numbers
      assert 4 in numbers
    end
  end

  describe "persistence" do
    @tag :tmp_dir
    test "a report with other failures and comparison counts round-trips at the current version",
         %{
           tmp_dir: dir,
           recorder: recorder
         } do
      targets = [
        ActiveSet.target("a", recorder),
        ActiveSet.target("b", recorder, %{fail: %{4 => :error}}),
        ActiveSet.target("c", recorder, %{fail: %{2 => :error}})
      ]

      model = Module.concat(__MODULE__, Model)
      assert {:error, report} = Compare.run(model, targets, max_commands: 5)
      assert [_ | _] = others(report)

      assert {:ok, path} = Persistence.save(report, dir)
      assert {:ok, <<"PD", 12::8, _checksum::32, _rest::binary>>} = File.read(path)

      assert {:ok, loaded} = Persistence.load(path)
      assert others(loaded) == others(report)
      assert Compare.field(loaded, :compare_counts) == Compare.field(report, :compare_counts)
    end

    @tag :tmp_dir
    test "a version 9 file is refused", %{tmp_dir: dir, recorder: recorder} do
      model = Module.concat(__MODULE__, Model)

      assert {:error, report} =
               Compare.run(
                 model,
                 [
                   ActiveSet.target("a", recorder),
                   ActiveSet.target("b", recorder, %{fail: %{1 => :error}})
                 ],
                 max_commands: 3
               )

      payload = %{format_version: 9, kind: :failure_report, report: report}
      term_binary = :erlang.term_to_binary(payload, [:compressed])
      checksum = :erlang.crc32(term_binary)
      path = Path.join(dir, "v9.pd")
      File.write!(path, <<"PD", 9::8, checksum::32, term_binary::binary>>)

      assert {:error, {:unsupported_format_version, 9, 12}} = Persistence.load(path)
    end
  end
end
