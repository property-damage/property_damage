defmodule PropertyDamage.SeedLibraryTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.SeedLibrary

  describe "load/1" do
    test "returns an error for a missing explicit path (likely a typo)" do
      # An explicit path that does not exist almost always means a typo.
      # Returning an empty library would silently mask it.
      assert {:error, :enoent} =
               SeedLibrary.load(Path.join(System.tmp_dir!(), "pd_seeds_typo_does_not_exist.json"))
    end

    test "round-trips a saved library" do
      path =
        Path.join(
          System.tmp_dir!(),
          "pd_seeds_roundtrip_#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm(path) end)

      {:ok, library} =
        SeedLibrary.add_seed(SeedLibrary.new(), 123,
          model: "MyModel",
          failure_type: :check_failed
        )

      assert :ok = SeedLibrary.save(library, path)
      assert {:ok, loaded} = SeedLibrary.load(path)
      assert length(loaded.entries) == 1
    end
  end
end
