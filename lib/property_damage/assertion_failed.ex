# `AssertionFailed` is an intentional public name: it is raised by the
# documented `fail!/2` and matched on by users since v0.1. The "*Error"
# naming convention is enforced for every other exception in the codebase.
# credo:disable-for-next-line Credo.Check.Consistency.ExceptionNames
defmodule PropertyDamage.AssertionFailed do
  @moduledoc """
  Simple exception for assertion failures.

  This exception is raised by `PropertyDamage.fail!/2` and provides a
  convenient way to fail assertions with a message and optional data.

  ## Usage

      PropertyDamage.fail!("balance is negative")
      PropertyDamage.fail!("balance is negative", balance: -50, account_id: "acc_123")

  ## Custom Exceptions

  For richer error context, define your own exception types:

      defmodule MyApp.BalanceViolation do
        defexception [:balance, :account_id, :requirement]

        def message(%{balance: b, account_id: id}) do
          "Account \#{id} has negative balance: \#{b}"
        end
      end

      # In your projection:
      raise %MyApp.BalanceViolation{balance: -50, account_id: "acc_123", requirement: "REQ-001"}

  The framework is exception-agnostic - it will catch and report any exception type.
  """

  defexception [:message, :data]

  @impl true
  def message(%__MODULE__{message: msg, data: nil}), do: msg
  def message(%__MODULE__{message: msg, data: data}) when map_size(data) == 0, do: msg
  def message(%__MODULE__{message: msg, data: data}), do: "#{msg}: #{inspect(data)}"
end
