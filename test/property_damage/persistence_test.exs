defmodule PropertyDamage.PersistenceTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Persistence, FailureReport, Sequence}

  # Test command/event structs for version capture
  defmodule TestCommand do
    defstruct [:id, :amount]
  end

  defmodule TestEvent do
    defstruct [:id, :amount, :status]
  end

  defp create_test_report(opts \\ []) do
    seed = Keyword.get(opts, :seed, 12345)
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
    test "saves and loads report with v2 format", %{tmp_dir: dir} do
      report = create_test_report()
      {:ok, path} = Persistence.save(report, dir)

      assert File.exists?(path)
      {:ok, loaded} = Persistence.load(path)

      assert loaded.seed == report.seed
      assert loaded.failure_type == report.failure_type
      assert loaded.check_name == report.check_name
    end

    @tag :tmp_dir
    test "includes metadata in v2 files", %{tmp_dir: dir} do
      report = create_test_report()
      {:ok, path} = Persistence.save(report, dir)

      # Read raw binary to verify format
      {:ok, <<"PD", version::8, _checksum::32, _rest::binary>>} = File.read(path)
      assert version == 2
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
      <<"PD", 2::8, _checksum::32, term_binary::binary>> = binary
      payload = :erlang.binary_to_term(term_binary, [:safe])

      # Add a fake dependency that will be missing (guaranteed to trigger warning)
      modified_metadata = %{payload.metadata | dependency_versions: %{fake_missing_app: "1.0.0"}}
      modified_payload = %{payload | metadata: modified_metadata}
      new_term_binary = :erlang.term_to_binary(modified_payload, [:compressed])
      new_checksum = :erlang.crc32(new_term_binary)

      File.write!(path, <<"PD", 2::8, new_checksum::32, new_term_binary::binary>>)

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
      <<"PD", 2::8, _checksum::32, term_binary::binary>> = binary
      payload = :erlang.binary_to_term(term_binary, [:safe])

      modified_metadata = %{payload.metadata | dependency_versions: %{fake_missing_app: "1.0.0"}}
      modified_payload = %{payload | metadata: modified_metadata}
      new_term_binary = :erlang.term_to_binary(modified_payload, [:compressed])
      new_checksum = :erlang.crc32(new_term_binary)

      File.write!(path, <<"PD", 2::8, new_checksum::32, new_term_binary::binary>>)

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

  describe "v1 backward compatibility" do
    @tag :tmp_dir
    test "loads v1 files without warnings", %{tmp_dir: dir} do
      report = create_test_report()

      # Create a v1 format file manually
      payload = %{version: 1, report: report}
      term_binary = :erlang.term_to_binary(payload, [:compressed])
      checksum = :erlang.crc32(term_binary)
      v1_binary = <<"PD", 1::8, checksum::32, term_binary::binary>>

      path = Path.join(dir, "v1-test.pd")
      File.write!(path, v1_binary)

      # Should load without warnings
      {:ok, loaded} = Persistence.load(path)
      assert loaded.seed == report.seed
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
      <<"PD", 2::8, _checksum::32, term_binary::binary>> = binary
      payload = :erlang.binary_to_term(term_binary, [:safe])

      modified_metadata =
        put_in(payload.metadata[:property_damage_version], "0.0.1-fake")

      modified_payload = %{payload | metadata: modified_metadata}
      new_term_binary = :erlang.term_to_binary(modified_payload, [:compressed])
      new_checksum = :erlang.crc32(new_term_binary)

      File.write!(path, <<"PD", 2::8, new_checksum::32, new_term_binary::binary>>)

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
end
