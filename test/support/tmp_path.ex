defmodule PropertyDamage.Test.TmpPath do
  @moduledoc false
  # Paths under the system tmp dir that two test suites running at once on one
  # host cannot share. `System.unique_integer/1` restarts at a similar value in
  # every VM, and the tmp dir is common to all VMs, so each path carries the OS
  # pid as well.

  @doc "The system tmp dir, for assertions about where a path lives."
  def root, do: System.tmp_dir!()

  @doc """
  A path under the tmp dir that is distinct per OS process and per call.

  The result is `<tmp>/<prefix>_<os pid>_<counter>`; add an extension with
  `<>` when the path names a file.
  """
  def unique(prefix) do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}_#{System.pid()}_#{System.unique_integer([:positive])}"
    )
  end

  @doc """
  A path under the tmp dir that is distinct per OS process and stable across
  calls, for a test that computes the same path again in a later callback.
  """
  def scoped(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.pid()}")
  end
end
