defmodule PropertyDamage.FailureIdentityPersistenceTest do
  # A failure has three levels of name: `Failure.class/1` (the broad class),
  # `Failure.kind/1` (the fine-grained kind) and `Failure.report_kind/1` (the
  # five outcomes a report sorts into). The saved file, the JSON export and the
  # `FailureReport` accessors each use one word for one level: `kind` is the
  # fine kind and `report_kind` is the outcome. A file saved before that
  # split is refused.
  #
  # Calls to functions the change introduces go through `apply/3`, so this
  # file compiles before the change and each test fails on its own.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Persistence}

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @persistence_fixtures Path.join(@fixtures, "persistence")
  @current_version PropertyDamage.Persistence.version()

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

  # A real run whose second command fails the `at_most_one` check.
  defp failing_report do
    assert {:error, %FailureReport{} = report} =
             PropertyDamage.run(
               model: Model,
               targets: [Adapter],
               seed: 12_345,
               max_runs: 1,
               shrink: false
             )

    report
  end

  # The real report with its failure swapped for an idempotency violation, a
  # fine kind that sorts into the `:check_failed` outcome, so the two levels
  # of name differ.
  defp no_failure_report do
    report = failing_report()
    %{report | trace: %{report.trace | outcome: :pass}}
  end

  defp idempotency_report do
    report = failing_report()
    failure = Failure.from_signature(:idempotency_violation, nil)
    %{report | trace: %{report.trace | outcome: {:fail, failure}}}
  end

  defp header_version(path) do
    <<"PD", version::8, _rest::binary>> = File.read!(path)
    version
  end

  describe "an older format version" do
    test "a format-18 report is refused by load/1 and load_trace/1" do
      path = Path.join(@persistence_fixtures, "format_18_report.pd")
      assert header_version(path) == 18

      assert {:error, {:unsupported_format_version, 18, @current_version}} =
               Persistence.load(path)

      assert {:error, {:unsupported_format_version, 18, @current_version}} =
               Persistence.load_trace(path)
    end

    @tag :tmp_dir
    test "the format-18 refusal comes from the header version, not from the file", %{
      tmp_dir: dir
    } do
      # Control: the refusal above is about the header version, not the file.
      # Re-framing the same bytes under the current header version gets past the version check
      # (it may fail later, on its checksum or payload, but not as unsupported).
      path = Path.join(@persistence_fixtures, "format_18_report.pd")
      <<"PD", _v::8, rest::binary>> = File.read!(path)
      reframed = Path.join(dir, "reframed.pd")
      File.write!(reframed, <<"PD", @current_version::8, rest::binary>>)

      refute match?({:error, {:unsupported_format_version, _, _}}, Persistence.load(reframed))
    end
  end

  describe "a saved report" do
    @tag :tmp_dir
    test "round-trips at the current format with its report kind derived from the failure", %{
      tmp_dir: dir
    } do
      report = failing_report()
      {:ok, path} = Persistence.save(report, dir)

      assert header_version(path) == @current_version
      <<"PD", _v::8, _crc::32, bin::binary>> = File.read!(path)
      assert %{format_version: @current_version, report: stored} = :erlang.binary_to_term(bin)
      assert Map.get(stored, :report_kind) == :check_failed
      refute Map.has_key?(stored, :kind)

      assert {:ok, loaded} = Persistence.load(path)
      assert loaded == report

      assert Map.get(loaded, :report_kind) ==
               Failure.report_kind(FailureReport.failure_reason(loaded))

      assert Map.get(loaded, :report_kind) == :check_failed
    end
  end

  describe "export_json/1" do
    defp exported(report), do: report |> Persistence.export_json() |> Jason.decode!()

    test "names the fine kind `kind` and the outcome `report_kind`" do
      json = exported(idempotency_report())

      assert json["format"] == 2
      assert json["failure"]["kind"] == "idempotency_violation"
      assert json["report_kind"] == "check_failed"
      refute Map.has_key?(json, "failure_type")
    end

    test "gives each real check failure the same fine kind and outcome words" do
      json = exported(failing_report())

      assert json["failure"]["kind"] == "check_failed"
      assert json["report_kind"] == "check_failed"

      assert json["failure"]["check_name"] ==
               "at_most_one"
    end

    test "names the fine kind of each other failure `kind`" do
      report = failing_report()
      other = Failure.from_signature(:adapter_error, nil)

      with_other = %{
        report
        | other_failures: [%{variant: %{index: 0, name: "a"}, root: 1, failure: other}]
      }

      assert [entry] = exported(with_other)["other_failures"]

      assert entry["kind"] == "adapter_error"
      assert entry["check_name"] == nil
      refute Map.has_key?(entry, "failure_type")
    end
  end

  describe "tracked fixtures" do
    test "every tracked persistence fixture is refused as older, or loads at the current version" do
      files = Path.wildcard(Path.join(@persistence_fixtures, "*.pd"))
      versions = files |> Enum.map(&header_version/1) |> Enum.sort()
      assert versions == Enum.sort(versions) and 16 in versions and 17 in versions
      assert 18 in versions

      for path <- files do
        version = header_version(path)
        assert Path.basename(path) == "format_#{version}_report.pd"

        if version < @current_version do
          assert {:error, {:unsupported_format_version, ^version, @current_version}} =
                   Persistence.load(path)
        else
          assert {:ok, _report} = Persistence.load(path)
        end
      end
    end

    test "the seed characterization goldens store no format version to regenerate" do
      goldens = Path.wildcard(Path.join([@fixtures, "seed_characterization", "*.exs"]))
      assert length(goldens) >= 3

      for path <- goldens do
        text = File.read!(path)
        refute text =~ "format_version", "#{path} stores a format version"
        refute text =~ "failure_type", "#{path} uses the retired word"
      end
    end

    test "the tracked bench replay artifact is at format 3 and holds a signature" do
      path =
        Path.join([
          __DIR__,
          "..",
          "..",
          "benches",
          "cachex_bench",
          "test",
          "fixtures",
          "Model_seed3.replay.exs"
        ])

      text = File.read!(path)
      assert String.starts_with?(text, "# PropertyDamage replay artifact, format 3\n")
      assert text =~ ~r/^  format: 3,$/m
      assert text =~ ~r/^    signature: \{/m
      refute text =~ "variant_index:"
    end
  end

  describe "failure kind levels" do
    test "FailureReport.kind/1 is the fine kind where the report kind is the outcome" do
      report = idempotency_report()

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      assert apply(FailureReport, :kind, [report]) == :idempotency_violation
      assert Map.get(report, :report_kind) == :check_failed
      assert Failure.kind(FailureReport.failure_reason(report)) == :idempotency_violation
    end

    test "FailureReport.kind/1 is :unknown without a failure" do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      assert apply(FailureReport, :kind, [no_failure_report()]) == :unknown
    end

    test "FailureReport.kind_summary/1 replaces failure_type_summary/1" do
      Code.ensure_loaded!(FailureReport)

      assert function_exported?(FailureReport, :kind_summary, 1)
      refute function_exported?(FailureReport, :failure_type_summary, 1)
      refute function_exported?(FailureReport, :failure_type, 1)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      assert apply(FailureReport, :kind_summary, [failing_report()]) ==
               "Invariant Violation: at_most_one"
    end

    test "Failure.report_kind/1 sorts every failure into one of its six outcomes" do
      cases = [
        {:check_failed, Failure.from_signature(:idempotency_violation, nil)},
        {:execution_failed, Failure.from_signature(:adapter_error, nil)},
        {:execution_failed, Failure.from_signature(:unknown, nil)},
        {:diverged, Failure.from_signature(:diverged, {Count, :at_most_one})},
        {:did_not_converge, Failure.from_signature(:did_not_converge, {Count, :at_most_one})},
        {:setup_failed, Failure.from_signature(:setup_failed, nil)},
        {:latency_exceeded, Failure.from_signature(:latency_exceeded, :p99)}
      ]

      for {expected, failure} <- cases do
        assert Failure.report_kind(failure) == expected
      end

      assert cases |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 6
      assert Failure.report_kind(:not_a_failure) == nil
    end
  end
end
