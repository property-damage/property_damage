defmodule PropertyDamage.Next.Adapter do
  @moduledoc """
  The behaviour of an adapter: the bridge from a plan to the system under test.

  PD calls `c:setup/2` once per execution, `c:execute/3` once per step, and
  `c:teardown/1` at the end if the adapter defines it. The adapter receives
  each step's command and assigns with every PD value replaced by a
  concrete one; it never receives a placeholder, a mint marker, a slot, a
  journal key or any other PD identifier.

  ## Steps that yield

  A step in a lane can let a step of the other lane run in the middle of
  it. `execute/3` marks such a place by returning `{:yield, continuation}`.
  The work done so far stays done. `continuation` is a function of no
  arguments that does the rest when PD calls it, and it answers as
  `execute/3` does: `{:ok, events}`, `{:error, reason}`, or
  `{:yield, continuation}` again. Between the yield and the call, PD may
  run part of a step of the other lane. PD calls each continuation at most
  once, in the process that called `execute/3`, and
  `PropertyDamage.Next.Runtime.ack/2` sees the same step running as during
  `execute/3`. In the prefix, and in a plan without lanes, PD calls the
  continuation right away. A step in a lane may yield at most `:yields`
  times (default 1); one more yield fails the step. If another step fails
  first, PD never calls the open continuation. `teardown/1` then runs as
  after any failure and must release whatever that continuation held. A
  raise, exit or throw in a continuation fails the step, as one in
  `execute/3` does. An adapter that never yields works unchanged: each of
  its steps is one part that nothing interleaves.

  In a lane, the system may refuse a command that its own lane's state
  allowed, because the other lane got there first. Report such a refusal
  as an event, so the projections fold it. `{:error, reason}` still fails
  the run.

  Any other answer from `execute/3` or from a continuation, a `{:yield, _}`
  whose second element is not a function of no arguments included, fails
  the step with an `ArgumentError`.
  """

  alias PropertyDamage.Next.Runtime

  @doc "Starts what the execution needs and returns the context `execute/3` receives."
  @callback setup(config :: term(), runtime :: Runtime.t()) ::
              {:ok, context :: term()} | {:error, term()}

  @typedoc "The rest of a step that yielded: called with no arguments, it answers as `execute/3` does."
  @type continuation :: (-> {:ok, [struct()]} | {:error, term()} | {:yield, continuation()})

  @doc """
  Runs one command against the system and returns the events it observed.

  A step in a lane may instead return `{:yield, continuation}` at a place
  where a step of the other lane may run, and `continuation` does the rest
  when PD calls it. See "Steps that yield" in the module documentation.
  """
  @callback execute(command :: struct(), assigns :: map(), context :: term()) ::
              {:ok, [struct()]} | {:error, term()} | {:yield, continuation()}

  @doc "Stops what `setup/2` started."
  @callback teardown(context :: term()) :: term()

  @optional_callbacks teardown: 1
end
