defmodule Mix.Tasks.PdGenTest do
  # These tasks mutate the current working directory and write files, so the
  # tests must not run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Gen.Adapter, as: GenAdapter
  alias Mix.Tasks.Pd.Gen.Command, as: GenCommand
  alias Mix.Tasks.Pd.Gen.Model, as: GenModel
  alias Mix.Tasks.Pd.Gen.Projection, as: GenProjection

  # Each test gets its own unique temp dir (uniqueness derived from the test
  # name, not Date/random). We cd into it so the generators, which write
  # relative to the cwd, land in an isolated sandbox we tear down afterwards.
  setup context do
    slug =
      context.test
      |> Atom.to_string()
      |> String.replace(~r/[^a-zA-Z0-9]+/, "_")

    tmp = Path.join(System.tmp_dir!(), "pd_gen_test_#{slug}")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    old_cwd = File.cwd!()
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(old_cwd)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  # Compile generated source, returning the list of defined modules. Purges
  # them immediately so distinct tests can reuse names without redefinition
  # warnings and so we don't leak modules into the test VM.
  defp assert_compiles(content) do
    compiled =
      try do
        capture_io(:stderr, fn ->
          send(self(), {:compiled, Code.compile_string(content)})
        end)

        receive do
          {:compiled, mods} -> mods
        end
      rescue
        e ->
          flunk("generated code failed to compile: #{Exception.message(e)}\n\n#{content}")
      end

    for {mod, _bin} <- compiled do
      :code.purge(mod)
      :code.delete(mod)
    end

    compiled
  end

  # Stricter variant: the generated module must compile with NO warnings.
  # Used for the command generator, whose output must satisfy the
  # `PropertyDamage.Command` behaviour exactly (a missing required callback or
  # a stray `@impl` would warn). The adapter/model/projection stubs reference
  # optional third-party modules (Req/GRPC) and legitimately warn, so they use
  # `assert_compiles/1` instead.
  defp assert_compiles_without_warnings(content) do
    warnings =
      capture_io(:stderr, fn ->
        for {mod, _bin} <- Code.compile_string(content) do
          :code.purge(mod)
          :code.delete(mod)
        end
      end)

    assert warnings == "",
           "expected generated code to compile without warnings, got:\n#{warnings}\n\nsource:\n#{content}"
  end

  describe "Mix.Tasks.Pd.Gen.Command" do
    test "generates a basic command module" do
      capture_io(fn ->
        GenCommand.run(["GenCmdBasic.Commands.CreateThing"])
      end)

      path = "lib/gen_cmd_basic/commands/create_thing.ex"
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "use PropertyDamage.Command"
      # The required Command callback is generator/1 (not new!/2), returning a
      # map generator the executor maps to the struct.
      assert content =~ "def generator"
      refute content =~ "def new!"
      # No fields -> constant empty-map generator.
      assert content =~ "StreamData.constant(%{})"

      assert_compiles_without_warnings(content)
    end

    test "generates a command with fields and probe semantics" do
      capture_io(fn ->
        GenCommand.run([
          "GenCmdFields.Commands.UpdateThing",
          "--fields",
          "thing_ref,name",
          "--semantics",
          "probe"
        ])
      end)

      path = "lib/gen_cmd_fields/commands/update_thing.ex"
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "def generator"
      refute content =~ "def new!"
      assert content =~ "use PropertyDamage.Command, execution: :probe"
      assert content =~ "thing_ref:"
      assert content =~ "name:"
      assert content =~ "PropertyDamage.Generator.merge_overrides(overrides)"

      assert_compiles_without_warnings(content)
    end
  end

  describe "Mix.Tasks.Pd.Gen.Adapter" do
    test "generates an http adapter by default" do
      capture_io(fn ->
        GenAdapter.run(["GenAdapterHttp.HTTPAdapter"])
      end)

      path = "lib/gen_adapter_http/http_adapter.ex"
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "@behaviour PropertyDamage.Adapter"
      assert content =~ "def setup"
      assert content =~ "def teardown"
      assert content =~ "def execute"
      assert content =~ "HTTP adapter"

      assert_compiles(content)
    end

    test "generates a grpc adapter with --type grpc" do
      capture_io(fn ->
        GenAdapter.run(["GenAdapterGrpc.GRPCAdapter", "--type", "grpc"])
      end)

      path = "lib/gen_adapter_grpc/grpc_adapter.ex"
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "@behaviour PropertyDamage.Adapter"
      assert content =~ "def setup"
      assert content =~ "def teardown"
      assert content =~ "def execute"
      assert content =~ "gRPC adapter"

      assert_compiles(content)
    end

    test "generates a direct adapter with --type direct" do
      capture_io(fn ->
        GenAdapter.run(["GenAdapterDirect.DirectAdapter", "--type", "direct"])
      end)

      path = "lib/gen_adapter_direct/direct_adapter.ex"
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "@behaviour PropertyDamage.Adapter"
      assert content =~ "def setup"
      assert content =~ "def teardown"
      assert content =~ "def execute"
      assert content =~ "Direct adapter"

      assert_compiles(content)
    end
  end

  describe "Mix.Tasks.Pd.Gen.Model" do
    test "generates a basic model module" do
      capture_io(fn ->
        GenModel.run(["GenModelBasic.TestModel"])
      end)

      path = "lib/gen_model_basic/test_model.ex"
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "@behaviour PropertyDamage.Model"
      assert content =~ "def commands"
      assert content =~ "def command_sequence_projection"
      assert content =~ "def assertion_projections"

      assert_compiles(content)
    end

    test "generates a model with commands, projection, and assertion projections" do
      capture_io(fn ->
        GenModel.run([
          "GenModelFull.TestModel",
          "--commands",
          "CreateUser,UpdateUser,DeleteUser",
          "--projection",
          "GenModelFull.Projections.ModelState",
          "--assertion-projections",
          "BalanceChecker,AuditLog"
        ])
      end)

      path = "lib/gen_model_full/test_model.ex"
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "def commands"
      assert content =~ "CreateUser"
      assert content =~ "UpdateUser"
      assert content =~ "DeleteUser"
      assert content =~ "GenModelFull.Projections.ModelState"
      assert content =~ "BalanceChecker"
      assert content =~ "AuditLog"

      assert_compiles(content)
    end
  end

  describe "Mix.Tasks.Pd.Gen.Projection" do
    test "generates a projection module" do
      capture_io(fn ->
        GenProjection.run(["GenProjBasic.Projections.ModelState"])
      end)

      path = "lib/gen_proj_basic/projections/model_state.ex"
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "use PropertyDamage.Model.Projection"
      assert content =~ "def init"
      assert content =~ "def apply"

      assert_compiles(content)
    end
  end
end
