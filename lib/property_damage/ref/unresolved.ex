defmodule PropertyDamage.Ref.Unresolved do
  @moduledoc """
  Sentinel module used to indicate a Ref has not yet been resolved.

  ## Why a Module Instead of an Atom?

  Using a dedicated module atom avoids ambiguity with legitimate values.
  The atom `PropertyDamage.Ref.Unresolved` cannot be a legitimate resolved
  value from a System Under Test, whereas a simple atom like `:unresolved`
  theoretically could be (e.g., if an API returns `{:ok, :unresolved}`).

  ## Usage

  This module is used internally by `PropertyDamage.Ref` as the default
  value for the `resolved` field. You should not need to reference this
  module directly - use `Ref.resolved?/1` instead to check resolution status.
  """
end
