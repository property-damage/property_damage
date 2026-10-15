defmodule PropertyDamage.ModuleCheck do
  @moduledoc false
  # Reflection on a user module (a model, command, projection, adapter,
  # injector or simulator). `function_exported?/3` is false for a module that
  # is compiled but not loaded yet, and the VM loads modules lazily in
  # interactive mode, so a check on a module nothing has called yet would
  # silently report a callback as missing. `exports?/3` loads the module first.

  @doc """
  True when `module` can be loaded and exports `fun/arity`.
  """
  @spec exports?(module(), atom(), arity()) :: boolean()
  def exports?(module, fun, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end
