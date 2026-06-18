defmodule PropertyDamage.SeedLibraryTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.SeedLibrary

  defp tmp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "pd_seeds_#{name}_#{System.unique_integer([:positive])}.json"
    )
  end

  describe "load/1" do
    test "returns an error for a missing explicit path (likely a typo)" do
      # An explicit path that does not exist almost always means a typo.
      # Returning an empty library would silently mask it.
      assert {:error, :enoent} =
               SeedLibrary.load(Path.join(System.tmp_dir!(), "pd_seeds_typo_does_not_exist.json"))
    end

    test "round-trips a saved library" do
      path = tmp_path("roundtrip")
      on_exit(fn -> File.rm(path) end)

      {:ok, library} =
        SeedLibrary.add_seed(SeedLibrary.new(), 123,
          model: "MyModel",
          failure_type: :check_failed
        )

      assert :ok = SeedLibrary.save(library, path)
      assert {:ok, loaded} = SeedLibrary.load(path)
      assert length(loaded.entries) == 1
      assert hd(loaded.entries).consecutive_passes == 0
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
      assert entry.failure_type == :check_failed
      assert entry.check_name == :balance
      refute Map.has_key?(entry, :status)
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
      {:ok, lib} = SeedLibrary.add_seed(SeedLibrary.new(), 1, failure_type: :check_failed)
      lib = SeedLibrary.record_run(lib, 1, failed: false)
      lib = SeedLibrary.record_run(lib, 1, failed: false)
      assert seed_entry(lib, 1).consecutive_passes == 2

      lib =
        SeedLibrary.record_run(lib, 1,
          failed: true,
          failure_type: :poll_timeout,
          check_name: :eventually
        )

      assert seed_entry(lib, 1).consecutive_passes == 0
      assert seed_entry(lib, 1).failure_type == :poll_timeout
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

  defp seed_entry(library, seed), do: Enum.find(library.entries, &(&1.seed == seed))
end
