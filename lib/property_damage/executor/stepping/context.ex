defmodule PropertyDamage.Executor.Stepping.Context do
  @moduledoc """
  The per-run inputs shared by every `PropertyDamage.Executor.Stepping.step/4`
  of one sequence.

  These do not change from one command to the next, so they are bundled once
  rather than passed on every call: the `model` orchestrating the run, the
  `adapter` bridging to the SUT and the `adapter_context` its `setup/1`
  returned, and the `event_queue` async/injected events flow through (`nil`
  when the run has no injector adapters). `target_name` names the target in
  the warnings `PropertyDamage.Executor.Stepping.step_teardown/4` logs (`nil`
  when there is no target name).
  """

  @enforce_keys [:model, :adapter, :adapter_context]
  defstruct [:model, :adapter, :adapter_context, :event_queue, :target_name]

  @type t :: %__MODULE__{
          model: module(),
          adapter: module(),
          adapter_context: term(),
          event_queue: pid() | nil,
          target_name: String.t() | nil
        }
end
