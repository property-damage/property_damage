defmodule PropertyDamage.FailureReport.BundleStringCompiledTest do
  # A module compiled from a string reports the file "nofile". That is no
  # file at all, so the bundle lists the module without a source instead of
  # naming "nofile" as a missing source.
  use ExUnit.Case, async: false

  alias PropertyDamage.Docs
  alias PropertyDamage.Test.BundleSupport, as: B
  alias PropertyDamage.Test.ReportLayout, as: RL

  setup do
    previous = System.get_env("PD_LOG")
    System.delete_env("PD_LOG")

    on_exit(fn ->
      if previous, do: System.put_env("PD_LOG", previous), else: System.delete_env("PD_LOG")
    end)

    :ok
  end

  test "a model compiled from a string has no file, no source and no missing source" do
    report = RL.report(:diverged)
    assert {:ok, %{file: "nofile", moduledoc: moduledoc}} = Docs.fetch(report.model)

    bundle = B.build(report)
    entry = B.module_entry(bundle, report.model)

    assert entry["file"] == nil
    assert entry["source"] == nil
    assert entry["lines"] == nil
    assert entry["resolution"] == "unavailable"
    assert entry["moduledoc"] == moduledoc
    refute "nofile" in bundle["missing_sources"]
  end
end
