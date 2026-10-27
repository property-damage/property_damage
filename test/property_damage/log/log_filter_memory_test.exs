defmodule PropertyDamage.Log.LogFilterMemoryTest do
  # A report's tag filter lives only in memory (DR-054 decision 9 extends to
  # it): a saved and loaded report holds none, a version-15 file saved before
  # the field existed still loads, and the persistence version stays 15.
  use ExUnit.Case, async: false

  alias PropertyDamage.Persistence
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.TmpPath

  setup do
    F.compile!()
    dir = TmpPath.unique("pd_log_filter_memory")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp loaded!(path) do
    case Persistence.load(path) do
      {:ok, report} -> report
      {:ok, report, _warnings} -> report
      other -> flunk("load failed: #{inspect(other)}")
    end
  end

  test "a saved and loaded report holds no filter, and the file is still version 15", %{dir: dir} do
    report = F.filter_report!(log: [only: [:http], except: [:body]])

    assert F.field(report, :log_filter) == [only: [:http], except: [:body]],
           "control: it holds one"

    assert {:ok, path} = Persistence.save(report, dir)
    assert <<"PD", 15, _checksum::32, term::binary>> = File.read!(path)

    saved = inspect(:erlang.binary_to_term(term), limit: :infinity, printable_limit: :infinity)
    refute saved =~ "only: [:http]"

    loaded = loaded!(path)
    assert F.field(loaded, :log_filter, :missing) == nil
    refute F.plain(loaded) =~ "Log filter"
  end
end
