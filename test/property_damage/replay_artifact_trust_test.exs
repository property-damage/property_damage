defmodule PropertyDamage.ReplayArtifactTrustTest do
  # A replay artifact is read from a file nobody vouches for. The loader
  # creates no atom the file names, loads no module the file names, and builds
  # only the structs of loaded command modules and of the framework's own
  # artifact structs. A failing run never overwrites the artifact of another
  # failure of the same seed.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.Lockstep.{GuardedStepModel, StepAdapter}
  alias PropertyDamage.Test.ReplayFixtures, as: R

  @header "# PropertyDamage replay artifact, format 1"

  # A minimal well-formed artifact for F.Model, with `prefix:` holding PAYLOAD.
  defp artifact(payload) do
    """
    #{@header}
    # model: PropertyDamage.Test.ExpansionFor.Model
    %{
      choices: %{"ref" => []},
      failure: %{kind: :diverged, name: :x, root_index: 0, variant_index: 0},
      format: 1,
      model: PropertyDamage.Test.ExpansionFor.Model,
      prefix: [#{payload}],
      roots: [],
      run: 1,
      seed: 1,
      targets: [%{expansion: :random, name: "ref"}]
    }
    """
  end

  defp existing_atom?(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  describe "atoms" do
    test "an artifact naming an atom this system does not know is refused, naming it" do
      name = "pd_unknown_atom_" <> Integer.to_string(System.unique_integer([:positive]))
      refute existing_atom?(name)

      assert {:error, reason} = R.parse_artifact(artifact(":" <> name))
      assert R.reason_text(reason) =~ name
      refute existing_atom?(name)
    end

    test "a module alias resolves to its module whether or not its segments are atoms" do
      assert {:ok, %{prefix: [F.Model]}} =
               R.parse_artifact(artifact("PropertyDamage.Test.ExpansionFor.Model"))
    end
  end

  describe "struct modules" do
    setup do
      dir = R.tmp_dir!()
      stamp = System.unique_integer([:positive])
      module = Module.concat([PropertyDamage, ReplayArtifactTrustTest, "Hooked#{stamp}"])
      Process.register(self(), :pd_replay_artifact_trust_probe)

      [{^module, beam}] =
        Code.compile_string("""
        defmodule #{inspect(module)} do
          @on_load :hook
          defstruct [:n]
          def generator(_overrides \\\\ %{}), do: StreamData.constant(%{})
          def hook do
            if pid = Process.whereis(:pd_replay_artifact_trust_probe), do: send(pid, :hooked)
            :ok
          end
        end
        """)

      receive do
        :hooked -> :ok
      after
        0 -> :ok
      end

      File.write!(Path.join(dir, "#{module}.beam"), beam)
      :code.add_patha(String.to_charlist(dir))
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        :code.purge(module)
        :code.delete(module)
      end)

      %{module: module}
    end

    test "a struct of a module on the code path that is not loaded is refused and stays unloaded",
         %{module: module} do
      assert :code.is_loaded(module) == false

      assert {:error, {:unknown_struct_module, ^module}} =
               R.parse_artifact(artifact("%#{inspect(module)}{n: 1}"))

      assert :code.is_loaded(module) == false
      refute_received :hooked
    end

    test "a struct of a loaded module that is not a command is refused" do
      assert {:error, {:unknown_struct_module, URI}} =
               R.parse_artifact(artifact(~s|%URI{host: "x"}|))
    end

    test "a replay of an artifact whose root is not a command fails before any target is set up" do
      dir = R.tmp_dir!()

      text =
        artifact("")
        |> String.replace("roots: [],", ~s|roots: [%{root_id: 0, command: %URI{host: "x"}}],|)
        |> String.replace(
          ~s|choices: %{"ref" => []}|,
          ~s|choices: %{"ref" => [%{aliases: %{}, commands: [%URI{host: "x"}], entry: nil, root_id: 0}]}|
        )

      path = Path.join(dir, "Model_seed1.replay.exs")
      File.write!(path, text)

      error =
        assert_raise ArgumentError, fn ->
          PropertyDamage.run(
            model: F.Model,
            targets: [F.target("ref")],
            only: [replay: path],
            replay_dir: false
          )
        end

      assert Exception.message(error) =~ "URI"
      assert F.drain() == []
    end
  end

  describe "file names" do
    defp failing_run(name, dir) do
      PropertyDamage.run(
        model: GuardedStepModel,
        targets: [{StepAdapter, name: name, config: %{name: name, bad_at: 1}}],
        max_runs: 1,
        max_commands: 6,
        seed: 12_345,
        validate: false,
        replay_dir: dir
      )
    end

    test "a failure of the same seed under other targets writes beside the first artifact" do
      dir = R.tmp_dir!()

      assert {:error, %FailureReport{replay_status: :written} = first} = failing_run("a", dir)
      assert Path.basename(first.replay_path) == "GuardedStepModel_seed12345.replay.exs"
      bytes = File.read!(first.replay_path)

      assert {:error, %FailureReport{replay_status: :written} = second} = failing_run("b", dir)
      assert Path.basename(second.replay_path) == "GuardedStepModel_seed12345_2.replay.exs"
      assert File.read!(first.replay_path) == bytes
      assert FailureReport.replay_command(second) =~ second.replay_path

      assert {:error, %FailureReport{} = again} = failing_run("a", dir)
      assert again.replay_path == first.replay_path
    end
  end
end
