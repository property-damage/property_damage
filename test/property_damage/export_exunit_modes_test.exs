defmodule PropertyDamage.ExportExUnitModesTest do
  # The exported ExUnit test from a real failing run: the default form is a
  # regression guard that fails while the bug is present, the reproduce form
  # fails once the failure no longer reproduces, and the generated source
  # compiles without warnings and is already formatted.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PropertyDamage.{Export, FailureReport}
  alias PropertyDamage.Test.TmpPath

  defmodule Bump do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.integer(1..3)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Bumped do
    @moduledoc false
    defstruct [:step]
  end

  defmodule Counter do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{double: false}

    @impl true
    def apply(state, %Bumped{step: step}), do: %{state | double: state.double or step != 1}
    def apply(state, _event), do: state

    @check every: 1
    def bumps_by_one(state, _), do: not state.double or PropertyDamage.fail!("bumped twice")
  end

  defmodule Model do
    @moduledoc false
    use PropertyDamage.Model

    @impl true
    def commands, do: [Bump]

    @impl true
    def command_sequence_projection, do: Counter

    @impl true
    def check_projections, do: [Counter]
  end

  # Answers every `Bump` with a step of one, or two under `bug: true`.
  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Bump{}, %{bug: bug}, _runtime),
      do: {:ok, [%Bumped{step: if(bug, do: 2, else: 1)}]}
  end

  @buggy [{Adapter, config: %{bug: true}}]
  @fixed [{Adapter, config: %{bug: false}}]

  defp report!(replay_dir) do
    assert {:error, %FailureReport{} = report} =
             PropertyDamage.run(
               model: Model,
               targets: @buggy,
               seed: 11,
               max_runs: 1,
               max_commands: 7,
               replay_dir: replay_dir
             )

    report
  end

  defp tmp_dir! do
    dir = TmpPath.unique("pd_export_modes")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # The generated test body as a plain function, so it compiles without
  # registering an ExUnit module and can be called. The run inside it writes
  # no replay artifact.
  defp body!(code, name) do
    compilable =
      code
      |> String.replace(~r/defmodule \S+ do/, "defmodule #{inspect(name)} do", global: false)
      |> String.replace("use ExUnit.Case, async: true", "import ExUnit.Assertions")
      |> String.replace(~r/\n\s*@tag [^\n]+/, "")
      |> String.replace(~r/test "[^"]+" do/, "def __regression_check__ do")
      |> String.replace("PropertyDamage.run(", "PropertyDamage.run(replay_dir: false, ")

    {_result, diagnostics} = Code.with_diagnostics(fn -> Code.compile_string(compilable) end)
    on_exit(fn -> :code.purge(name) && :code.delete(name) end)
    {name, diagnostics}
  end

  defp outcome(module) do
    capture_io(fn -> send(self(), {:outcome, catch_flunk(module)}) end)
    assert_received {:outcome, outcome}
    outcome
  end

  defp catch_flunk(module) do
    module.__regression_check__()
    :passed
  rescue
    e in ExUnit.AssertionError -> {:failed, e.message}
  end

  describe "the default form" do
    test "is the regression guard and fails with its own message while the bug is present" do
      code = Export.to_exunit(report!(false))

      assert code =~ "Bug has resurfaced!"
      refute code =~ ~r/(?<!PropertyDamage\.)FailureReport\./

      {module, diagnostics} = body!(code, PDExportModesGuardBuggy)
      assert diagnostics == []
      assert {:failed, message} = outcome(module)
      assert message =~ "Bug has resurfaced!"
    end

    test "passes once the bug is fixed" do
      code = Export.to_exunit(report!(false), targets: @fixed)
      {module, []} = body!(code, PDExportModesGuardFixed)

      assert outcome(module) == :passed
    end

    test "states in its moduledoc that it fails while any failure is found" do
      code = Export.to_exunit(report!(false))

      assert code =~ "fails if the run finds any failure"
      refute code =~ "If the bug reappears, it will fail."
    end
  end

  describe "the reproduce form" do
    test "passes while the failure reproduces" do
      code = Export.to_exunit(report!(false), expect_fixed: false)
      {module, diagnostics} = body!(code, PDExportModesReproduceBuggy)

      assert diagnostics == []
      assert outcome(module) == :passed
    end

    test "fails once the failure no longer reproduces" do
      code = Export.to_exunit(report!(false), expect_fixed: false, targets: @fixed)
      {module, []} = body!(code, PDExportModesReproduceFixed)

      assert {:failed, message} = outcome(module)
      assert message =~ "no longer reproduces"
    end

    test "states in its moduledoc that it fails once the failure stops reproducing" do
      code = Export.to_exunit(report!(false), expect_fixed: false)

      assert code =~ "fails if the run no longer fails"
      refute code =~ "If the bug reappears, it will fail."
    end
  end

  describe "the generated source" do
    test "re-runs the seed with the run's max_commands: when the report has no artifact" do
      code = Export.to_exunit(report!(false))

      assert code =~ "seed: 11"
      assert code =~ "max_commands: 7"
    end

    test "lists no unused command list and no placeholder struct literal" do
      code = Export.to_exunit(report!(false))

      refute code =~ "_commands = ["
      refute code =~ "%PropertyDamage.Placeholder{"
      assert code =~ ~r/#\s+%PropertyDamage.ExportExUnitModesTest.Bump\{/
    end

    test "compiles without warnings under the replay form" do
      code = Export.to_exunit(report!(tmp_dir!()))

      assert code =~ "only: [replay:"
      refute code =~ "as: Adapter"
      assert {_module, []} = body!(code, PDExportModesReplayForm)
    end

    test "replays a copy of the artifact kept beside the test, as the docs show" do
      failure = report!(tmp_dir!())
      regressions = tmp_dir!()

      copy = Path.join(regressions, Path.basename(failure.replay_path))
      File.cp!(failure.replay_path, copy)
      test_code = PropertyDamage.Export.to_exunit(%{failure | replay_path: copy})

      File.rm!(failure.replay_path)
      assert test_code =~ "only: [replay: #{inspect(copy)}]"
      {module, []} = body!(test_code, PDExportModesCopiedArtifact)
      assert {:failed, message} = outcome(module)
      assert message =~ "Bug has resurfaced!"
    end

    test "is already formatted in both forms" do
      report = report!(false)

      for opts <- [[], [expect_fixed: false]] do
        code = Export.to_exunit(report, opts)
        formatted = IO.iodata_to_binary([Code.format_string!(code), "\n"])

        assert code == formatted
      end
    end
  end
end
