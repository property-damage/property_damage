defmodule PropertyDamage.ReplayArtifactFreshVmTest do
  # A replay artifact replays in a VM that has loaded neither the framework's
  # failure modules nor the user's projections, as under `mix test path:line`
  # running one regression test alone. Inside this suite other tests have
  # loaded those modules already, so each case runs in a new OS process: one
  # VM writes the artifact by a failing run, and a second VM replays it.
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.TmpPath

  @moduletag timeout: 120_000

  # The check name exists only as an atom of `FreshVmReplay.Check`; nothing
  # in the framework or in the scripts below names it.
  @check_name "fresh_vm_bump_small"

  @user_source """
  defmodule FreshVmReplay.Bump do
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\\\ %{}) do
      %{n: StreamData.integer(1..9)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule FreshVmReplay.Bumped do
    defstruct [:n]
  end

  defmodule FreshVmReplay.State do
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state
  end

  defmodule FreshVmReplay.Check do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: FreshVmReplay.Bumped
    def #{@check_name}(_state, %{n: n}) do
      n <= 5 or PropertyDamage.fail!("a bump above five")
    end
  end

  defmodule FreshVmReplay.Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%FreshVmReplay.Bump{n: n}, _ctx, _runtime), do: {:ok, [%FreshVmReplay.Bumped{n: n}]}
  end

  defmodule FreshVmReplay.Model do
    use PropertyDamage.Model

    @impl true
    def commands, do: [FreshVmReplay.Bump]

    @impl true
    def command_sequence_projection, do: FreshVmReplay.State

    @impl true
    def check_projections, do: [FreshVmReplay.Check]
  end
  """

  # `mix test` starts the application before any test; so do the scripts.
  @write_script """
  {:ok, _apps} = Application.ensure_all_started(:property_damage)
  [dir] = System.argv()

  {:error, _report} =
    PropertyDamage.run(
      model: FreshVmReplay.Model,
      targets: [FreshVmReplay.Adapter],
      seed: 1,
      max_runs: 50,
      replay_dir: dir
    )
  """

  # Replays the artifact at each path in a VM that has not loaded the
  # failure modules or the projection, printing one line per replay. The
  # script makes no remote call into `PropertyDamage.Failure`: compiling such
  # a call loads the module before the script runs.
  @replay_script """
  {:ok, _apps} = Application.ensure_all_started(:property_damage)

  IO.puts("LOADED failure=\#{:code.is_loaded(PropertyDamage.Failure) != false} " <>
    "projection=\#{:code.is_loaded(FreshVmReplay.Check) != false}")

  for path <- System.argv() do
    try do
      {:error, report} =
        PropertyDamage.run(
          model: FreshVmReplay.Model,
          targets: [FreshVmReplay.Adapter],
          only: [replay: path],
          replay_dir: false
        )

      IO.puts("REPLAYED kind=\#{report.report_kind} name=\#{report.failure_reason.type.name}")
    rescue
      e in ArgumentError -> IO.puts("RAISED " <> Exception.message(e))
    end
  end
  """

  setup do
    dir = TmpPath.unique("pd_replay_fresh_vm")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)
    source = Path.join(dir, "fresh_vm_replay.ex")
    File.write!(source, @user_source)
    libraries = Enum.flat_map(library_ebins(), &["-pa", &1])
    {output, status} = cmd("elixirc", libraries ++ ["-o", ebin, source], dir)
    assert status == 0, output

    paths = ["-pa", ebin | libraries]
    replay_dir = Path.join(dir, "replays")
    {output, status} = script(dir, "write.exs", @write_script, paths, [replay_dir])
    assert status == 0, output
    assert [artifact] = Path.wildcard(Path.join(replay_dir, "*.replay.exs")), output

    [dir: dir, paths: paths, artifact: artifact]
  end

  test "an artifact naming a failure kind and a projection's check name replays", ctx do
    text = File.read!(ctx.artifact)
    assert text =~ "kind: :check_failed"
    assert text =~ "name: :#{@check_name}"

    {output, status} = script(ctx.dir, "replay.exs", @replay_script, ctx.paths, [ctx.artifact])

    assert status == 0, output
    assert output =~ "LOADED failure=false projection=false"
    refute output =~ "RAISED", output
    assert output =~ "REPLAYED kind=check_failed name=#{@check_name}", output
  end

  test "an atom no loaded module holds stays unknown after the replay loads its modules",
       ctx do
    unknown = "fresh_vm_no_such_check_#{System.unique_integer([:positive])}"
    edited = Path.join(ctx.dir, "edited.replay.exs")

    File.write!(
      edited,
      String.replace(File.read!(ctx.artifact), "name: :#{@check_name}", "name: :#{unknown}")
    )

    # The intact artifact replays first, so every module the replay loads is
    # loaded when the edited one is read.
    {output, status} =
      script(ctx.dir, "replay.exs", @replay_script, ctx.paths, [ctx.artifact, edited])

    assert status == 0, output
    assert output =~ "REPLAYED kind=check_failed name=#{@check_name}", output

    assert output =~
             "RAISED `only: [replay: #{inspect(edited)}]`: the replay artifact names " <>
               ":#{inspect(unknown)}, which this system does not know (no such atom)",
           output
  end

  defp script(dir, name, source, paths, args) do
    path = Path.join(dir, name)
    File.write!(path, source)
    cmd("elixir", paths ++ [path | args], dir)
  end

  defp cmd(executable, args, dir) do
    assert path = System.find_executable(executable), "no #{executable} on the PATH"
    System.cmd(path, args, cd: dir, stderr_to_stdout: true, env: [{"MIX_ENV", nil}])
  end

  # The compiled framework and the libraries it calls at run time.
  defp library_ebins do
    for module <- [PropertyDamage, StreamData, NimbleOptions, Jason, :telemetry],
        do: module |> :code.which() |> Path.dirname()
  end
end
