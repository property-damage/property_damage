defmodule PropertyDamage.Next.CorpusKeptTest do
  # The kept list on the corpus harness: every site where PD's own engine
  # drew a StreamData generator that a dependent field or assign returned.
  # The corpus engine answers it as `kept:` and `mix pd.corpus` prints it.
  #
  # async: false because the task runs "app.start" and prints to stdout,
  # which is captured.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Mix.Tasks.Pd.Corpus, as: CorpusTask
  alias PropertyDamage.Corpus.{Engine, Entry}
  alias PropertyDamage.Next.Test.FullRefund
  alias PropertyDamage.Test.TmpPath

  @site %{site: :field, command: FullRefund.Memo, key: :text, spec: nil}

  defmodule MemoOnlyModel do
    @moduledoc false
    # Memos only, so the first slot draws the dependent StreamData site.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.FullRefund

    def steps, do: StepSpec.normalize([FullRefund.Memo])
    def simulator, do: FullRefund.Model.simulator()
    def command_sequence_projection, do: FullRefund.Model.command_sequence_projection()
    def check_projections, do: FullRefund.Model.check_projections()
  end

  defp entry(model) do
    %Entry{
      name: "memo_refund",
      engine: Engine.Next,
      system: FullRefund.System,
      bug: :lost_full_refund,
      model: model,
      adapter: FullRefund.Adapter,
      minimum: nil,
      seeds: [1, 2],
      max_commands: 6
    }
  end

  test "the corpus engine's result lists a dependent StreamData site as kept" do
    for seed <- [1, 2] do
      capture_log(fn ->
        result = Engine.Next.run(entry(FullRefund.MemoModel), seed, 200)
        assert @site in Map.fetch!(result, :kept)
      end)
    end
  end

  test "an entry whose run options ask for raise mode reports the site as kept, not as found" do
    # The entry's run_opts field is built at run time, so the suite compiles
    # before the field exists.
    entry = struct!(entry(MemoOnlyModel), run_opts: [dependent_stream_data: :raise])

    for seed <- [1, 2] do
      result = Engine.Next.run(entry, seed, 50)

      refute result.found?
      assert result.plans_until_found == nil
      assert result.shrunk == nil
      assert result.shrink_runs == 0
      assert Map.fetch!(result, :kept) == [@site]
    end
  end

  test "an entry with the default run options reports the site as kept too" do
    for entry <- [entry(MemoOnlyModel), struct!(entry(MemoOnlyModel), run_opts: [])] do
      capture_log(fn ->
        result = Engine.Next.run(entry, 1, 50)

        refute result.found?
        assert Map.fetch!(result, :kept) == [@site]
      end)
    end
  end

  test "a model with no such site has an empty kept list" do
    result = Engine.Next.run(entry(FullRefund.Model), 1, 200)
    assert Map.fetch!(result, :kept) == []
  end

  test "mix pd.corpus prints the kept list for an entry" do
    dir = TmpPath.unique("pd_next_kept_corpus")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "memo_refund.exs"), """
    %PropertyDamage.Corpus.Entry{
      name: "memo_refund",
      engine: PropertyDamage.Corpus.Engine.Next,
      system: PropertyDamage.Next.Test.FullRefund.System,
      bug: :lost_full_refund,
      model: PropertyDamage.Next.Test.FullRefund.MemoModel,
      adapter: PropertyDamage.Next.Test.FullRefund.Adapter,
      minimum: nil,
      seeds: [1, 2],
      max_commands: 6
    }
    """)

    output =
      capture_io(fn ->
        capture_log(fn -> CorpusTask.exec(["--dir", dir, "--cap", "100"]) end)
      end)

    assert output =~ "memo_refund"
    assert output =~ inspect(FullRefund.Memo)
    assert output =~ "text"
  end
end
