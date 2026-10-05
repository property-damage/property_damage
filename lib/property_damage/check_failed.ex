# `CheckFailed` is an intentional public name: it is the exception raised by
# the documented `fail!/2`, so users match on it directly. The "*Error"
# naming convention is enforced for every other exception in the codebase.
# credo:disable-for-next-line Credo.Check.Consistency.ExceptionNames
defmodule PropertyDamage.CheckFailed do
  @moduledoc """
  Exception raised by `PropertyDamage.fail!/2` when a check fails.

  It carries a message and optional data, so a check can fail with context.

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
