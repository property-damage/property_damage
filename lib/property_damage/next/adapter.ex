defmodule PropertyDamage.Next.Adapter do
  @moduledoc """
  The behaviour of an adapter: the bridge from a plan to the system under test.

  PD calls `c:setup/2` once per execution, `c:execute/3` once per step, and
  `c:teardown/1` at the end if the adapter defines it. The adapter receives
  each step's command and assigns with every PD value replaced by a
  concrete one; it never receives a placeholder, a mint marker, a slot, a
  journal key or any other PD identifier.
  """

  alias PropertyDamage.Next.Runtime

  @doc "Starts what the execution needs and returns the context `execute/3` receives."
  @callback setup(config :: term(), runtime :: Runtime.t()) ::
              {:ok, context :: term()} | {:error, term()}

  @doc "Runs one command against the system and returns the events it observed."
  @callback execute(command :: struct(), assigns :: map(), context :: term()) ::
              {:ok, [struct()]} | {:error, term()}

  @doc "Stops what `setup/2` started."
  @callback teardown(context :: term()) :: term()

  @optional_callbacks teardown: 1
end
