defmodule PropertyDamage.Model.Projection.CompareAttribute do
  @moduledoc false
  # `use PropertyDamage.Model.Projection` imports this module's `@/1` in place
  # of `Kernel.@/1`. It keeps the options of `@compare` as code, so `using:`
  # can be a private capture, a closure or a call to an imported helper, and
  # passes every other attribute to `Kernel.@/1` unchanged.
  import Kernel, except: [@: 1]

  alias PropertyDamage.Model.Projection

  defmacro @{:compare, meta, [opts]} do
    Projection.__compare_attribute__(opts, meta, __CALLER__)
  end

  defmacro @expression do
    quote do: Kernel.@(unquote(expression))
  end
end
