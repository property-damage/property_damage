defmodule PropertyDamage.PersistenceFormatVersionTest do
  # The saved-file format carries a version number. A file of an older version
  # is refused, and a current-version file whose event log names a source the
  # engine never produces is refused rather than loaded.
  use ExUnit.Case, async: true

  @version PropertyDamage.Persistence.version()

  alias PropertyDamage.{FailureReport, Persistence}

  # Reports saved at earlier format versions. A format-17 report's sequence
  # and trace carry fields that format 18 dropped, and a format-18 report
  # stores its outcome under a field format 19 renamed.
  @older_fixtures [
    {16, Path.join([__DIR__, "..", "fixtures", "persistence", "format_16_report.pd"])},
    {17, Path.join([__DIR__, "..", "fixtures", "persistence", "format_17_report.pd"])},
    {18, Path.join([__DIR__, "..", "fixtures", "persistence", "format_18_report.pd"])}
  ]
  @engine_sources [:command, :injector, :telemetry, :stutter, :mock, :injected, :resource_poller]

  defmodule Send do
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides), do: StreamData.constant(%{})
  end

  defmodule Sent do
    defstruct [:n]
  end

  defmodule Count do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}
    @impl true
    def apply(state, %Sent{}), do: %{state | count: state.count + 1}
    def apply(state, _), do: state

    @check every: 1
    def at_most_one(state, _cmd_or_event) do
      state.count < 2 or PropertyDamage.fail!("two sends", count: state.count)
    end
  end

  defmodule Model do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model
    @impl true
    def commands, do: [Send]
    @impl true
    def command_sequence_projection, do: Count
    @impl true
    def check_projections, do: [Count]
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(_command, _state), do: []
  end

  defmodule Adapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Send{}, _ctx, _runtime), do: {:ok, [%Sent{n: 1}]}
  end

  # A real run that fails on its second command, with a non-empty event log.
  defp failing_report do
    assert {:error, %FailureReport{} = report} =
             PropertyDamage.run(
               model: Model,
               targets: [Adapter],
               seed: 12_345,
               max_runs: 1,
               shrink: false
             )

    assert FailureReport.event_log(report) != []
    report
  end

  defp saved_header(path) do
    <<"PD", version::8, _checksum::32, _rest::binary>> = File.read!(path)
    version
  end

  # Re-frames a saved file: `fun` rewrites the decoded payload, and the result
  # is encoded again under the header version the file already carried.
  defp reframe(path, fun) do
    <<"PD", version::8, _crc::32, bin::binary>> = File.read!(path)
    payload = fun.(:erlang.binary_to_term(bin))
    new_bin = :erlang.term_to_binary(payload, [:compressed])
    File.write!(path, <<"PD", version::8, :erlang.crc32(new_bin)::32, new_bin::binary>>)
    path
  end

  defp with_source(entries, source) do
    [first | rest] = entries
    [%{first | source: source} | rest]
  end

  describe "an older format version" do
    test "is refused by load/1" do
      for {version, path} <- @older_fixtures do
        assert {:error, {:unsupported_format_version, ^version, @version}} =
                 Persistence.load(path)
      end
    end

    test "is refused by load_trace/1" do
      for {version, path} <- @older_fixtures do
        assert {:error, {:unsupported_format_version, ^version, @version}} =
                 Persistence.load_trace(path)
      end
    end
  end

  describe "the previous format version" do
    @format_19 Path.join([__DIR__, "..", "fixtures", "persistence", "format_19_report.pd"])

    @tag :known_defect
    test "is refused by load/1" do
      assert {:error, {:unsupported_format_version, 19, Persistence.version()}} ==
               Persistence.load(@format_19)
    end

    @tag :known_defect
    test "is refused by load_trace/1" do
      assert {:error, {:unsupported_format_version, 19, Persistence.version()}} ==
               Persistence.load_trace(@format_19)
    end
  end

  describe "a saved report" do
    @tag :tmp_dir
    test "carries the current version in its header and payload, and loads back intact", %{
      tmp_dir: dir
    } do
      report = failing_report()
      {:ok, path} = Persistence.save(report, dir)

      version = saved_header(path)
      assert version == @version

      <<"PD", _v::8, _crc::32, bin::binary>> = File.read!(path)
      assert %{format_version: @version} = :erlang.binary_to_term(bin)

      assert {:ok, loaded} = Persistence.load(path)
      assert loaded.failure_reason == report.failure_reason
      assert loaded.seed == report.seed
      assert FailureReport.shrunk_sequence(loaded) == FailureReport.shrunk_sequence(report)
      assert FailureReport.event_log(loaded) == FailureReport.event_log(report)
      assert FailureReport.event_log(loaded) != []
    end

    @tag :tmp_dir
    test "round-trips an event log carrying each source the engine produces", %{tmp_dir: dir} do
      report = failing_report()
      [entry | _] = FailureReport.event_log(report)

      for source <- @engine_sources do
        log = [%{entry | source: source}]
        tagged = %{report | trace: %{report.trace | event_log: log}}
        {:ok, path} = Persistence.save(tagged, dir, filename: "#{source}.pd")

        assert {:ok, loaded} = Persistence.load(path)
        assert [%{source: ^source}] = FailureReport.event_log(loaded)
      end
    end

    @tag :tmp_dir
    test "is refused when its event log names a source the engine never produces", %{
      tmp_dir: dir
    } do
      {:ok, path} = Persistence.save(failing_report(), dir)

      reframe(path, fn payload ->
        update_in(payload.report.trace.event_log, &with_source(&1, :retired_source))
      end)

      assert {:error, {:unknown_event_source, :retired_source}} = Persistence.load(path)
    end

    @tag :tmp_dir
    test "is refused when its reference trace names a source the engine never produces", %{
      tmp_dir: dir
    } do
      report = failing_report()
      with_reference = %{report | reference_trace: report.trace}
      {:ok, path} = Persistence.save(with_reference, dir)

      reframe(path, fn payload ->
        update_in(payload.report.reference_trace.event_log, &with_source(&1, :retired_source))
      end)

      assert {:error, {:unknown_event_source, :retired_source}} = Persistence.load(path)
    end
  end

  describe "a saved trace" do
    @tag :tmp_dir
    test "is refused when its event log names a source the engine never produces", %{
      tmp_dir: dir
    } do
      {:ok, path} = Persistence.save_trace(failing_report().trace, dir)
      assert {:ok, _trace} = Persistence.load_trace(path)

      reframe(path, fn payload ->
        update_in(payload.trace.event_log, &with_source(&1, :retired_source))
      end)

      assert {:error, {:unknown_event_source, :retired_source}} = Persistence.load_trace(path)
    end
  end
end
