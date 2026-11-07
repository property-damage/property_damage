defmodule PropertyDamage.FailureReport.BundleFormattedModuleTest do
  # A module written as `defmodule M, do: (...)` has no `end` of its own, so
  # its last definition must still run through that definition's own `end`.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.BundleSupport, as: B
  alias PropertyDamage.Test.Compare

  setup do
    previous = System.get_env("PD_LOG")
    System.delete_env("PD_LOG")

    on_exit(fn ->
      if previous, do: System.put_env("PD_LOG", previous), else: System.delete_env("PD_LOG")
    end)

    :ok
  end

  test "the last definition of a formatted do: module runs through its own end" do
    p = "PropertyDamage.Test.Formatted#{B.suffix()}"

    unformatted =
      "defmodule #{p}.Formatted, do: (use PropertyDamage.Model; def commands, do: []\n\n" <>
        "def command_sequence_projection do\nPropertyDamage.Test.Compare.Counter\nend)\n"

    source = (unformatted |> Code.format_string!() |> IO.iodata_to_binary()) <> "\n"
    lines = String.split(source, "\n")

    compiled = B.compile_file(source, "formatted_model.ex")
    model = Module.concat([p, "Formatted"])
    report = B.hand_report(model, [{Compare.PayAdapter, "alice"}])

    entry = report |> B.build() |> B.module_entry(model)
    assert File.read!(compiled.file) == source

    csp = B.function_entry(entry, :command_sequence_projection, 0)
    assert Enum.at(lines, csp["from"] - 1) =~ "def command_sequence_projection do"
    assert Enum.at(lines, csp["to"] - 1) |> String.trim() == "end"

    commands = B.function_entry(entry, :commands, 0)
    assert commands["to"] == csp["from"] - 1
  end
end
