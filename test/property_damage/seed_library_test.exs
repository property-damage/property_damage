defmodule PropertyDamage.SeedLibraryTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.SeedLibrary
  alias PropertyDamage.Test.TmpPath

  defp tmp_path(name) do
    TmpPath.unique("pd_seeds_#{name}") <> ".json"
  end

  describe "load/1" do
    test "returns an error for a missing explicit path (likely a typo)" do
      # An explicit path that does not exist almost always means a typo.
      # Returning an empty library would silently mask it.
      assert {:error, :enoent} =
               SeedLibrary.load(TmpPath.scoped("pd_seeds_typo_does_not_exist") <> ".json")
    end

    test "round-trips a saved library" do
      path = tmp_path("roundtrip")
      on_exit(fn -> File.rm(path) end)

      {:ok, library} =
        SeedLibrary.add_seed(SeedLibrary.new(), 123,
          model: "MyModel",
          kind: :check_failed
        )

      assert :ok = SeedLibrary.save(library, path)
      assert {:ok, loaded} = SeedLibrary.load(path)
      assert length(loaded.entries) == 1
      assert hd(loaded.entries).consecutive_passes == 0
    end

    test "returns an error for valid JSON without entries" do
      path = tmp_path("no_entries")
      on_exit(fn -> File.rm(path) end)
      File.write!(path, "{}")

      assert {:error, {:invalid_library, _reason}} = SeedLibrary.load(path)
    end

    test "returns an error for a library of another version" do
      path = tmp_path("other_version")
      on_exit(fn -> File.rm(path) end)
      File.write!(path, ~s({"version": 999, "entries": []}))

      assert {:error, {:invalid_library, _reason}} = SeedLibrary.load(path)
    end

    test "tolerates a pre-DR-023 file with the old status/run_count fields" do
      path = tmp_path("legacy")
      on_exit(fn -> File.rm(path) end)

      legacy = %{
        version: 1,
        entries: [
          %{
            seed: 999,
            model: "OldModel",
            failure_type: "check_failed",
            check_name: "balance",
            tags: ["currency"],
            description: nil,
            discovered_at: "2024-01-01T00:00:00Z",
            last_run: nil,
            status: "flaky",
            run_count: 5,
            fail_count: 2
          }
        ]
      }

      File.write!(path, Jason.encode!(legacy))

      assert {:ok, loaded} = SeedLibrary.load(path)
      entry = hd(loaded.entries)
      assert entry.seed == 999
      assert entry.consecutive_passes == 0
      assert entry.kind == :check_failed
      assert entry.check_name == :balance
      refute Map.has_key?(entry, :status)
    end

    test "loads a version-2 entry's failure_type as its kind" do
      path = tmp_path("version_2")
      on_exit(fn -> File.rm(path) end)

      File.write!(
        path,
        ~s({"version": 2, "entries": [{"seed": 7, "failure_type": "poll_timeout"}]})
      )

      assert {:ok, %{version: 3, entries: [entry]}} = SeedLibrary.load(path)
      assert entry.kind == :poll_timeout
      refute Map.has_key?(entry, :failure_type)
    end

    test "a saved library stores the kind and loads it back" do
      path = tmp_path("version_3")
      on_exit(fn -> File.rm(path) end)

      {:ok, library} = SeedLibrary.add_seed(SeedLibrary.new(), 5, kind: :idempotency_violation)
      assert :ok = SeedLibrary.save(library, path)

      assert %{"version" => 3, "entries" => [%{"kind" => "idempotency_violation"} = saved]} =
               path |> File.read!() |> Jason.decode!()

      refute Map.has_key?(saved, "failure_type")
      assert {:ok, %{entries: [entry]}} = SeedLibrary.load(path)
      assert entry.kind == :idempotency_violation
    end

    test "loads a version-1 library's entries as a current library" do
      path = tmp_path("version_1")
      on_exit(fn -> File.rm(path) end)
      File.write!(path, ~s({"version": 1, "entries": [{"seed": 7}, {"seed": 8}]}))

      assert {:ok, %{version: 3, entries: entries}} = SeedLibrary.load(path)
      assert Enum.map(entries, & &1.seed) == [7, 8]
    end
  end

  describe "record_run/3 (streak semantics)" do
    test "a passing replay increments the consecutive-pass streak" do
      {:ok, lib} = SeedLibrary.add_seed(SeedLibrary.new(), 1)

      lib = SeedLibrary.record_run(lib, 1, failed: false)
      assert seed_entry(lib, 1).consecutive_passes == 1

      lib = SeedLibrary.record_run(lib, 1, failed: false)
      assert seed_entry(lib, 1).consecutive_passes == 2
      assert seed_entry(lib, 1).last_run != nil
    end

    test "a failing replay resets the streak and refreshes descriptive metadata" do
      {:ok, lib} = SeedLibrary.add_seed(SeedLibrary.new(), 1, kind: :check_failed)
      lib = SeedLibrary.record_run(lib, 1, failed: false)
      lib = SeedLibrary.record_run(lib, 1, failed: false)
      assert seed_entry(lib, 1).consecutive_passes == 2

      lib =
        SeedLibrary.record_run(lib, 1,
          failed: true,
          kind: :poll_timeout,
          check_name: :eventually
        )

      assert seed_entry(lib, 1).consecutive_passes == 0
      assert seed_entry(lib, 1).kind == :poll_timeout
      assert seed_entry(lib, 1).check_name == :eventually
    end
  end

  describe "prune/2" do
    test "removes entries whose streak reached K and reports the count" do
      {:ok, lib} = SeedLibrary.add_seed(SeedLibrary.new(), 1)
      {:ok, lib} = SeedLibrary.add_seed(lib, 2)
      {:ok, lib} = SeedLibrary.add_seed(lib, 3)

      lib = SeedLibrary.record_run(lib, 1, failed: false)
      lib = SeedLibrary.record_run(lib, 1, failed: false)
      lib = SeedLibrary.record_run(lib, 1, failed: false)
      lib = SeedLibrary.record_run(lib, 2, failed: false)

      {pruned, count} = SeedLibrary.prune(lib, 3)

      assert count == 1
      refute seed_entry(pruned, 1)
      assert seed_entry(pruned, 2).consecutive_passes == 1
      assert seed_entry(pruned, 3).consecutive_passes == 0
    end
  end

  describe "save/2 (atomic)" do
    test "leaves no temporary file behind and writes a loadable file" do
      path = tmp_path("atomic")
      on_exit(fn -> File.rm(path) end)

      {:ok, lib} = SeedLibrary.add_seed(SeedLibrary.new(), 42, model: "M")

      assert :ok = SeedLibrary.save(lib, path)
      assert {:ok, _} = SeedLibrary.load(path)

      siblings = Path.wildcard(path <> ".tmp*")
      assert siblings == [], "expected no leftover temp files, got: #{inspect(siblings)}"
    end
  end

  describe "save/2 (directory)" do
    test "creates a missing directory and saves the seed" do
      dir = TmpPath.unique("pd_seeds_dir")
      path = Path.join([dir, "nested", "seeds.json"])
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, lib} = SeedLibrary.add_seed(SeedLibrary.new(), 42, model: "M")

      assert :ok = SeedLibrary.save(lib, path)
      assert {:ok, loaded} = SeedLibrary.load(path)
      assert Enum.map(loaded.entries, & &1.seed) == [42]
    end

    test "returns an error when the directory cannot be created" do
      blocker = tmp_path("blocker")
      File.write!(blocker, "not a directory")
      on_exit(fn -> File.rm(blocker) end)

      {:ok, lib} = SeedLibrary.add_seed(SeedLibrary.new(), 42, model: "M")

      assert {:error, _reason} = SeedLibrary.save(lib, Path.join(blocker, "seeds.json"))
    end
  end

  defp seed_entry(library, seed), do: Enum.find(library.entries, &(&1.seed == seed))
end
