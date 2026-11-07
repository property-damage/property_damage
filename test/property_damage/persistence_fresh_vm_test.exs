defmodule PropertyDamage.PersistenceFreshVmTest do
  # A saved report loads in a VM that has not yet loaded the modules it names.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Persistence, Sequence}
  alias PropertyDamage.Test.Commands.CreateItem

  @moduletag :tmp_dir

  defp report(commands) do
    FailureReport.new(
      seed: 7,
      run_number: 1,
      original_sequence: Sequence.linear(commands),
      shrunk_sequence: Sequence.linear(commands),
      failed_at_index: 0,
      failure_reason:
        Failure.check_failed(PropertyDamage.Test.Projections.TestChecks, "Test failure"),
      event_log: [],
      model: PropertyDamage.Test.MinimalModel,
      targets: [{PropertyDamage.Test.TestAdapter, []}]
    )
  end

  # Loads `path` in a new OS process that has not touched the saved modules.
  defp load_in_fresh_vm(path) do
    code = """
    result =
      case PropertyDamage.Persistence.load(hd(System.argv())) do
        {:ok, _report} -> :ok
        {:error, reason} -> {:error, reason}
      end

    IO.puts(inspect(result))
    """

    {out, status} =
      System.cmd("mix", ["run", "--no-compile", "-e", code, path],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    out |> String.split("\n", trim: true) |> List.last()
  end

  test "a report naming a loadable module of a loaded application loads in a fresh VM", %{
    tmp_dir: dir
  } do
    {:ok, path} = Persistence.save(report([%CreateItem{name: "alice", quantity: 1}]), dir)
    assert load_in_fresh_vm(path) == ":ok"
  end

  test "a report naming a module of no loaded application is refused in a fresh VM", %{
    tmp_dir: dir
  } do
    name = Module.concat(__MODULE__, "Stranger#{System.unique_integer([:positive])}")
    {:module, ^name, _, _} = Module.create(name, quote(do: defstruct([:id])), __ENV__)
    {:ok, path} = Persistence.save(report([struct(name, id: "bob")]), dir)

    assert load_in_fresh_vm(path) == "{:error, :unsafe_terms}"
  end
end
