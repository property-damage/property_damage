defmodule PropertyDamage.PersistenceTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{FailureReport, Persistence, RunTrace, Sequence}

  # Test command/event structs for version capture
  defmodule TestCommand do
    defstruct [:id, :amount]
  end

  defmodule TestEvent do
    defstruct [:id, :amount, :status]
  end

  defp create_test_report(opts \\ []) do
    seed = Keyword.get(opts, :seed, 12_345)
    commands = Keyword.get(opts, :commands, [%TestCommand{id: "1", amount: 100}])
    events = Keyword.get(opts, :events, [])

    FailureReport.new(
      seed: seed,
      run_number: 1,
      original_sequence: Sequence.linear(commands),
      shrunk_sequence: Sequence.linear(commands),
      failed_at_index: 0,
      failure_reason: {:check_failed, :TestCheck, "Test failure"},
      event_log: events,
      model: TestModel,
      adapter: TestAdapter
    )
  end

  describe "save and load round-trip" do
    @tag :tmp_dir
    test "creates a missing target directory instead of failing silently", %{tmp_dir: dir} do
      report = create_test_report()
      nested = Path.join([dir, "failures", "nested"])
      refute File.dir?(nested)

      assert {:ok, path} = Persistence.save(report, nested)
      assert File.exists?(path)
      assert {:ok, _loaded} = Persistence.load(path)
    end

    @tag :tmp_dir
    test "saves and loads a report round-trip", %{tmp_dir: dir} do
      report = create_test_report()
      {:ok, path} = Persistence.save(report, dir)

      assert File.exists?(path)
      {:ok, loaded} = Persistence.load(path)

      assert loaded.seed == report.seed
      assert loaded.failure_type == report.failure_type
      assert loaded.check_name == report.check_name
    end

    @tag :tmp_dir
    test "writes the current format version in the header", %{tmp_dir: dir} do
      report = create_test_report()
      {:ok, path} = Persistence.save(report, dir)

      # Read raw binary to verify format
      {:ok, <<"PD", version::8, _checksum::32, _rest::binary>>} = File.read(path)
      assert version == 5
    end
  end

  describe "version warnings" do
    @tag :tmp_dir
    test "no warnings when versions match", %{tmp_dir: dir} do
      report = create_test_report()
      {:ok, path} = Persistence.save(report, dir)

      # Loading immediately should have no warnings
      result = Persistence.load(path)
      assert {:ok, _report} = result
    end

    @tag :tmp_dir
    test "returns warnings tuple when versions mismatch", %{tmp_dir: dir} do
      # Create a report and save it
      report = create_test_report()
      {:ok, path} = Persistence.save(report, dir)

      # Read the file and manually modify the metadata to simulate version mismatch
      {:ok, binary} = File.read(path)
      <<"PD", 5::8, _checksum::32, term_binary::binary>> = binary
      payload = :erlang.binary_to_term(term_binary, [:safe])

      # Add a fake dependency that will be missing (guaranteed to trigger warning)
      modified_metadata = %{payload.metadata | dependency_versions: %{fake_missing_app: "1.0.0"}}
      modified_payload = %{payload | metadata: modified_metadata}
      new_term_binary = :erlang.term_to_binary(modified_payload, [:compressed])
      new_checksum = :erlang.crc32(new_term_binary)

      File.write!(path, <<"PD", 5::8, new_checksum::32, new_term_binary::binary>>)

      # Now load should return warnings about missing dependency
      {:ok, _report, warnings} = Persistence.load(path)

      assert Enum.any?(warnings, fn
               {:dependency_missing, :fake_missing_app, "1.0.0"} -> true
               _ -> false
             end)
    end
  end

  describe "load!/1" do
    @tag :tmp_dir
    test "returns report when no warnings", %{tmp_dir: dir} do
      report = create_test_report()
      {:ok, path} = Persistence.save(report, dir)

      loaded = Persistence.load!(path)
      assert loaded.seed == report.seed
    end

    @tag :tmp_dir
    test "raises on version mismatch", %{tmp_dir: dir} do
      report = create_test_report()
      {:ok, path} = Persistence.save(report, dir)

      # Modify file to add fake missing dependency (guaranteed to trigger warning)
      {:ok, binary} = File.read(path)
      <<"PD", 5::8, _checksum::32, term_binary::binary>> = binary
      payload = :erlang.binary_to_term(term_binary, [:safe])

      modified_metadata = %{payload.metadata | dependency_versions: %{fake_missing_app: "1.0.0"}}
      modified_payload = %{payload | metadata: modified_metadata}
      new_term_binary = :erlang.term_to_binary(modified_payload, [:compressed])
      new_checksum = :erlang.crc32(new_term_binary)

      File.write!(path, <<"PD", 5::8, new_checksum::32, new_term_binary::binary>>)

      assert_raise ArgumentError, ~r/Version compatibility warnings/, fn ->
        Persistence.load!(path)
      end
    end

    test "raises on file not found" do
      assert_raise ArgumentError, ~r/Failed to load/, fn ->
        Persistence.load!("/nonexistent/path.pd")
      end
    end
  end

  describe "pre-v5 format refusal (DR-039)" do
    @tag :tmp_dir
    test "a v4 file is refused with a clear unsupported-version error", %{tmp_dir: dir} do
      # A pre-v5 file carries tuple-encoded positions inside its persisted terms;
      # rather than deep-convert arbitrary user structs, the loader refuses it and
      # asks the user to re-capture. Frame a valid v4-shaped payload and confirm
      # the version byte alone triggers the refusal (no decode is attempted).
      payload = %{format_version: 4, kind: :failure_report, report: create_test_report()}
      term_binary = :erlang.term_to_binary(payload, [:compressed])
      checksum = :erlang.crc32(term_binary)
      path = Path.join(dir, "v4-legacy.pd")
      File.write!(path, <<"PD", 4::8, checksum::32, term_binary::binary>>)

      assert {:error, {:unsupported_format_version, 4, 5}} = Persistence.load(path)
    end

    @tag :tmp_dir
    test "v1, v2, and v3 files are all refused", %{tmp_dir: dir} do
      for version <- [1, 2, 3] do
        term_binary = :erlang.term_to_binary(%{report: create_test_report()}, [:compressed])
        checksum = :erlang.crc32(term_binary)
        path = Path.join(dir, "v#{version}-legacy.pd")
        File.write!(path, <<"PD", version::8, checksum::32, term_binary::binary>>)

        assert {:error, {:unsupported_format_version, ^version, 5}} = Persistence.load(path)
      end
    end
  end

  describe "decode safety" do
    @tag :tmp_dir
    test "a valid-checksum file referencing an unknown atom is reported as unsafe terms, not corruption",
         %{tmp_dir: dir} do
      # Build a v5 payload whose value is an atom that does NOT exist in this VM.
      # The name is assembled as raw bytes so it is never interned by the test
      # itself; :erlang.binary_to_term/[:safe] refuses to create it. The bytes
      # are intact (checksum matches), so this is an environment mismatch
      # (unloaded modules/atoms), not corruption.
      name = "pd_persist_unknown_atom_" <> Integer.to_string(System.unique_integer([:positive]))

      term_binary =
        <<131, 116, 0, 0, 0, 1, 119, 6, "report", 119, byte_size(name)::8, name::binary>>

      checksum = :erlang.crc32(term_binary)
      path = Path.join(dir, "unknown-atom.pd")
      File.write!(path, <<"PD", 5::8, checksum::32, term_binary::binary>>)

      assert {:error, :unsafe_terms} = Persistence.load(path)
    end

    @tag :tmp_dir
    test "warns when a loaded report's struct shape has drifted from the current definition",
         %{tmp_dir: dir} do
      # Simulate a report saved by a PD version with a different FailureReport
      # field set: a struct-tagged map missing current fields. binary_to_term
      # reconstructs the stored shape verbatim, so a silent shape mismatch can
      # otherwise slip through.
      drifted = %{__struct__: FailureReport, seed: 7, run_number: 0}
      payload = %{kind: :failure_report, report: drifted, metadata: %{}}
      term_binary = :erlang.term_to_binary(payload, [:compressed])
      checksum = :erlang.crc32(term_binary)
      path = Path.join(dir, "drifted.pd")
      File.write!(path, <<"PD", 5::8, checksum::32, term_binary::binary>>)

      assert {:ok, _report, warnings} = Persistence.load(path)
      assert Enum.any?(warnings, &match?({:struct_shape_drift, _, _}, &1))
    end

    @tag :tmp_dir
    test "a normally saved report loads without a struct-drift warning", %{tmp_dir: dir} do
      report = create_test_report()
      {:ok, path} = Persistence.save(report, dir)

      assert {:ok, _loaded} = Persistence.load(path)
    end

    @tag :tmp_dir
    test "genuinely malformed bytes (no header) are still an invalid format", %{tmp_dir: dir} do
      path = Path.join(dir, "garbage.pd")
      File.write!(path, "not a pd file at all")

      assert {:error, :invalid_format} = Persistence.load(path)
    end

    @tag :tmp_dir
    test "rejects a compressed term whose declared size is a decompression bomb",
         %{tmp_dir: dir} do
      # The external term format flags compression with the byte 80 after the
      # 131 version byte, followed by a 32-bit declared uncompressed size. A
      # tiny file can claim a multi-gigabyte expansion; decoding it would let
      # the VM preallocate that much. The declared size must be bounded BEFORE
      # any decompression is attempted, so this is rejected as too large rather
      # than blindly inflated.
      huge_size = 4 * 1024 * 1024 * 1024 - 1
      term_binary = <<131, 80, huge_size::unsigned-32, "compressed-bytes-do-not-matter">>
      checksum = :erlang.crc32(term_binary)
      path = Path.join(dir, "bomb.pd")
      File.write!(path, <<"PD", 5::8, checksum::32, term_binary::binary>>)

      assert {:error, :term_too_large} = Persistence.load(path)
    end
  end

  describe "metadata listing does not exhaust the atom table" do
    @tag :tmp_dir
    test "an arbitrary filename check-name is not interned as a new atom", %{tmp_dir: dir} do
      # A directory full of crafted .pd filenames must not let `list/2` mint an
      # unbounded number of atoms. The check-name segment is parsed with
      # to_existing_atom; an unknown one drops to the (accurate) full-load path.
      novel_check = "pd_list_novel_check_atom_unique_marker"

      File.write!(
        Path.join(dir, "20251226T143000-check_failed-#{novel_check}-seed1.pd"),
        "garbage"
      )

      _ = Persistence.list(dir)

      assert_raise ArgumentError, fn -> String.to_existing_atom(novel_check) end
    end
  end

  describe "capture_dependency_versions/1" do
    test "captures versions from command structs" do
      report = create_test_report()
      versions = Persistence.capture_dependency_versions(report)

      # The test modules are in the test application
      # Versions map should contain atoms as keys
      assert is_map(versions)
    end

    test "handles reports with events" do
      event_entry = %PropertyDamage.EventLog.Entry{
        event: %TestEvent{id: "1", amount: 100, status: :ok},
        source: :command,
        command_index: 0,
        timestamp: DateTime.utc_now(),
        branch_id: nil
      }

      report = create_test_report(events: [event_entry])
      versions = Persistence.capture_dependency_versions(report)

      assert is_map(versions)
    end
  end

  describe "valid?/1" do
    @tag :tmp_dir
    test "returns true for valid file", %{tmp_dir: dir} do
      report = create_test_report()
      {:ok, path} = Persistence.save(report, dir)

      assert Persistence.valid?(path)
    end

    @tag :tmp_dir
    test "returns true for file with version warnings", %{tmp_dir: dir} do
      report = create_test_report()
      {:ok, path} = Persistence.save(report, dir)

      # Modify to cause version mismatch
      {:ok, binary} = File.read(path)
      <<"PD", 5::8, _checksum::32, term_binary::binary>> = binary
      payload = :erlang.binary_to_term(term_binary, [:safe])

      modified_metadata =
        put_in(payload.metadata[:property_damage_version], "0.0.1-fake")

      modified_payload = %{payload | metadata: modified_metadata}
      new_term_binary = :erlang.term_to_binary(modified_payload, [:compressed])
      new_checksum = :erlang.crc32(new_term_binary)

      File.write!(path, <<"PD", 5::8, new_checksum::32, new_term_binary::binary>>)

      # Still valid even with warnings
      assert Persistence.valid?(path)
    end

    test "returns false for nonexistent file" do
      refute Persistence.valid?("/nonexistent/path.pd")
    end

    @tag :tmp_dir
    test "returns false for corrupted file", %{tmp_dir: dir} do
      path = Path.join(dir, "corrupted.pd")
      File.write!(path, "not a valid pd file")

      refute Persistence.valid?(path)
    end
  end

  describe "trace composition (DR-033)" do
    @tag :tmp_dir
    test "a report round-trips with a working steps/1 and accessors", %{tmp_dir: dir} do
      command = %TestCommand{id: "1", amount: 100}

      event = %PropertyDamage.EventLog.Entry{
        timestamp: 0,
        command_index: 0,
        branch_id: nil,
        event: %TestEvent{id: "1", amount: 100, status: :failed},
        source: :command
      }

      report = create_test_report(commands: [command], events: [event])

      {:ok, path} = Persistence.save(report, dir)
      assert {:ok, loaded} = Persistence.load(path)

      # The embedded trace survives: accessors and the step interface work.
      assert FailureReport.shrunk_sequence(loaded) == Sequence.linear([command])
      assert FailureReport.event_log(loaded) == [event]
      assert [step] = FailureReport.steps(loaded)
      assert step.command == command
      assert Enum.map(step.entries, & &1.event) == [event.event]
      assert step.failed?
    end

    @tag :tmp_dir
    test "a standalone RunTrace round-trips via save_trace/load_trace", %{tmp_dir: dir} do
      command = %TestCommand{id: "1", amount: 5}

      trace =
        RunTrace.new(
          seed: 42,
          run_number: 0,
          model: TestModel,
          adapter: TestAdapter,
          plan: Sequence.linear([command]),
          plan_source: :generated,
          event_log: [],
          outcome: :pass
        )

      {:ok, path} = Persistence.save_trace(trace, dir)
      assert String.ends_with?(path, ".pdtrace")
      assert {:ok, loaded} = Persistence.load_trace(path)
      assert %RunTrace{} = loaded
      assert loaded == trace
      assert RunTrace.steps(loaded) |> Enum.map(& &1.command) == [command]
    end

    @tag :tmp_dir
    test "load_trace refuses a report file", %{tmp_dir: dir} do
      {:ok, path} = Persistence.save(create_test_report(), dir)
      assert {:error, :not_a_trace} = Persistence.load_trace(path)
    end
  end
end
