# A retry model: a payment carries an idempotency key minted per run, the
# predicted state keeps the payment as sent, and a retry sends one of the
# earlier payments again, key included. A retry must reach the system with
# the key of the payment it repeats.

defmodule PropertyDamage.Next.Test.Retry.Sent do
  @moduledoc false
  # The predicted event of a payment: the amount and the key as the plan
  # holds them.
  defstruct [:amount, :key]
end

defmodule PropertyDamage.Next.Test.Retry.Pay do
  @moduledoc false
  # Two keys minted in one step: an idempotency key and a request id.
  use PropertyDamage.Next.Command

  defstruct [:amount, :key, :request]

  def generator(_state, _opts) do
    %{amount: integer(1..1_000), key: mint_per_run(:uuid), request: mint_per_run(:uuid)}
  end
end

defmodule PropertyDamage.Next.Test.Retry.Again do
  @moduledoc false
  # Sends an earlier payment again, read back from the predicted state.
  use PropertyDamage.Next.Command

  defstruct [:original]

  def possible?(state), do: state.sent != []

  def generator(state, _opts), do: %{original: member_of(state.sent)}
end

defmodule PropertyDamage.Next.Test.Retry.Projection do
  @moduledoc false
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Next.Test.Retry.Sent

  @impl true
  def init, do: %{sent: []}

  @impl true
  def apply(state, %Sent{amount: amount, key: key}),
    do: %{state | sent: state.sent ++ [%{amount: amount, key: key}]}

  def apply(state, _event), do: state
end

defmodule PropertyDamage.Next.Test.Retry.Simulator do
  @moduledoc false
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Next.Test.Retry.{Pay, Sent}

  @impl true
  def simulate(%Pay{amount: amount, key: key}, _state), do: [%Sent{amount: amount, key: key}]
  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Next.Test.Retry.Model do
  @moduledoc false
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Retry.{Again, Pay, Projection, Simulator}

  def steps,
    do: StepSpec.normalize([{Pay, weight: 1}, {Again, weight: 1, when: &Again.possible?/1}])

  def simulator, do: Simulator
  def command_sequence_projection, do: Projection
end

defmodule PropertyDamage.Next.Test.Retry.Adapter do
  @moduledoc false
  # Records what the system receives. Config key `:recorder`: a pid that gets
  # `{:retry_received, kind, fields}` for each call, `fields` being exactly
  # the values sent to the system.
  @behaviour PropertyDamage.Next.Adapter

  alias PropertyDamage.Next.Test.Retry.{Again, Pay}

  @impl true
  def setup(config, _runtime), do: {:ok, %{recorder: config[:recorder]}}

  @impl true
  def execute(%Pay{amount: amount, key: key, request: request}, _assigns, context) do
    record(context, :pay, %{amount: amount, key: key, request: request})
    {:ok, []}
  end

  def execute(%Again{original: %{amount: amount, key: key}}, _assigns, context) do
    record(context, :again, %{amount: amount, key: key})
    {:ok, []}
  end

  defp record(%{recorder: pid}, kind, fields) when is_pid(pid),
    do: send(pid, {:retry_received, kind, fields})

  defp record(_context, _kind, _fields), do: :ok
end
