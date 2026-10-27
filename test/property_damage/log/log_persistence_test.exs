defmodule PropertyDamage.Log.PersistenceTest do
  # Log lines live only in memory (DR-054 decision 9): a saved report or
  # trace drops them and loads with `logs: %{}`, the format version stays
  # 15, a version-15 file saved before the field existed still loads and
  # prints, and no replay artifact or `:compact` output carries a line (the
  # `:json` output prints them under `logs`, in memory only). Every run here
  # logs a sentinel that its config holds only in parts, so a file holding the
  # whole sentinel got it from a line.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Persistence
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.TmpPath

  # Saved by the format-15 code before reports kept the reference trace,
  # from a run of two PayAdapter targets compared on this projection.
  @fixture Path.expand(
             "../../support/fixtures/persistence/v15_without_reference_fields.pd",
             __DIR__
           )

  @saved_projection_source """
  defmodule PropertyDamage.Test.SavedV15.Ledger do
    use PropertyDamage.Model.Projection
    alias PropertyDamage.Test.Compare.{Paid, Settled}

    @impl true
    def init, do: %{unsettled: %{}, settled: 0, by: nil}

    @impl true
    def apply(s, %Paid{n: n, amount: a, by: by}), do: %{s | unsettled: Map.put(s.unsettled, n, a), by: by}
    def apply(s, %Settled{n: n, amount: a}), do: %{s | unsettled: Map.delete(s.unsettled, n), settled: s.settled + a}
    def apply(s, _), do: s

    @compare every: 1
    def totals(s, _root) do
      if s.unsettled == %{}, do: %{settled: s.settled}, else: {:pending, :unsettled}
    end
  end
  """

  setup do
    dir = TmpPath.unique("pd_log_persistence")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp sentinel_script, do: %{0 => [{:sentinel, F.sentinel_parts()}]}

  # A :diverged report whose two targets each logged the sentinel.
  defp diverged_report do
    F.compile!()

    targets = [
      F.target("alice", %{quiet: true, script: sentinel_script()}),
      F.target("bob", %{quiet: true, script: sentinel_script(), skew_at: 1})
    ]

    report = F.report!(F.Model, targets)
    assert report.kind == :diverged
    assert F.plain(report) =~ F.sentinel(), "control: the report prints the sentinel"
    report
  end

  # The file's bytes, and the term it holds decoded and inspected in full.
  defp saved(path) do
    bytes = File.read!(path)
    assert <<"PD", 15, _checksum::32, term::binary>> = bytes
    {bytes, inspect(:erlang.binary_to_term(term), limit: :infinity, printable_limit: :infinity)}
  end

  defp refute_sentinel({bytes, decoded}) do
    refute String.contains?(bytes, F.sentinel()), "the sentinel is in the file's bytes"
    refute String.contains?(decoded, F.sentinel()), "the sentinel is in the saved term"
  end

  defp loaded!(path) do
    case Persistence.load(path) do
      {:ok, report} -> report
      {:ok, report, _warnings} -> report
      other -> flunk("load failed: #{inspect(other)}")
    end
  end

  test "a saved report drops every line and loads with logs: %{} on both traces", %{dir: dir} do
    # Persisted trace round trip: version 15, no line text in the file.
    report = diverged_report()
    assert F.field(report.trace, :logs, %{}) != %{}, "control: the variant's trace holds lines"
    assert F.field(report.reference_trace, :logs, %{}) != %{}, "control: the reference's too"

    assert {:ok, path} = Persistence.save(report, dir)
    refute_sentinel(saved(path))

    loaded = loaded!(path)
    assert F.field(loaded.trace, :logs) == %{}
    assert F.field(loaded.reference_trace, :logs) == %{}
  end

  test "a saved trace drops every line and loads with logs: %{}", %{dir: dir} do
    # save_trace/3 and load_trace/1 keep no line.
    report = diverged_report()

    assert {:ok, path} = Persistence.save_trace(report.trace, dir)
    refute_sentinel(saved(path))

    loaded =
      case Persistence.load_trace(path) do
        {:ok, trace} -> trace
        {:ok, trace, _warnings} -> trace
        other -> flunk("load_trace failed: #{inspect(other)}")
      end

    assert F.field(loaded, :logs) == %{}
  end

  test "a version-15 file saved before the field existed loads with logs: %{} and prints" do
    # The pre-field file's struct map lacks logs; loading sets it.
    define_saved_modules()
    report = loaded!(@fixture)

    assert F.field(report.trace, :logs) == %{}
    assert is_binary(Formatter.format(report, :terminal, color: false))
    assert is_binary(Formatter.format(report, :markdown))
  end

  test "a replay artifact and the compact output carry no line, the JSON only under logs", %{
    dir: dir
  } do
    # Replay artifacts are free of line text; :json prints it under `logs`
    # alone and :compact prints none.
    F.compile!()
    config = %{quiet: true, script: sentinel_script(), fail_at: 1}
    report = F.report!(F.Model, [F.target("alice", config)], replay_dir: dir)
    assert F.plain(report) =~ F.sentinel(), "control: the report prints the sentinel"
    assert F.field(report, :replay_status) == :written, "control: the artifact was written"

    files = Path.wildcard(Path.join(dir, "**/*"))
    assert Enum.any?(files, &File.regular?/1), "control: the directory holds the artifact"

    for file <- files,
        File.regular?(file),
        do: refute(File.read!(file) =~ F.sentinel(), "#{file} holds the sentinel")

    json = report |> Formatter.format(:json) |> Jason.decode!()
    assert Jason.encode!(json["logs"]) =~ F.sentinel(), "control: logs carries the sentinel"
    refute json |> Map.delete("logs") |> Jason.encode!() =~ F.sentinel()
    refute Formatter.format(report, :compact) =~ F.sentinel()
  end

  # Loading decodes only atoms that exist, so the saved run's projection and
  # model are defined before the file is read, and every module is loaded.
  defp define_saved_modules do
    :global.trans({{__MODULE__, :saved_v15}, self()}, fn ->
      projection = PropertyDamage.Test.SavedV15.Ledger

      unless Code.ensure_loaded?(projection) do
        {:ok, [^projection | _]} = Compare.compile(@saved_projection_source)
      end

      model = PropertyDamage.Test.SavedV15.Model
      unless Code.ensure_loaded?(model), do: Compare.define_model!(model, [projection])
    end)

    Enum.each(Application.spec(:property_damage, :modules), &Code.ensure_loaded!/1)
  end
end
