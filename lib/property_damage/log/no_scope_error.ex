defmodule PropertyDamage.Log.NoScopeError do
  @moduledoc """
  Raised when `PropertyDamage.log/2` finds no scope (DR-054 decision 4).

  A line needs a scope to land in: an execution point of a run, found in the
  calling process or in a process of its `$callers` list. The message names
  the call site, the calling process and the three ways to give the call a
  scope.

  Inside `c:PropertyDamage.Adapter.execute/3` the raise becomes an adapter
  error, which the failure report classifies as a test code error.
  """

  defexception [:file, :line, :pid]

  @type t :: %__MODULE__{
          file: String.t() | nil,
          line: non_neg_integer() | nil,
          pid: pid() | nil
        }

  @impl true
  def message(%__MODULE__{} = error) do
    """
    PropertyDamage.log/2 found no scope at #{site(error)} in process #{inspect(error.pid)}.
    A log line lands only in a scope, and neither this process nor any process in its $callers holds one. Fix it in one of three ways:
      * call it from code PropertyDamage runs (an adapter callback, a command, a nemesis or mock handler);
      * wrap the code in PropertyDamage.Log.capture/1;
      * log through PropertyDamage.Runtime.log/3 with the runtime the adapter was handed.\
    """
  end

  defp site(%__MODULE__{file: nil}), do: "an unknown call site"
  defp site(%__MODULE__{file: file, line: line}), do: "#{Path.relative_to_cwd(file)}:#{line}"
end
