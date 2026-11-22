defmodule PropertyDamage.Corpus.Entry do
  @moduledoc """
  One corpus entry: a small system with a single seeded bug, a model that can
  find it, and the hand-written smallest plan that exposes it.

  Fields:

    * `name` - descriptive label, also the key of the entry's table row.
    * `engine` - a module implementing `PropertyDamage.Corpus.Engine`. It runs
      the entry; the rest of the harness never looks inside.
    * `system` - the module of the system under test.
    * `bug` - the switch naming the seeded bug. The harness runs the entry once
      with it set and once with `nil` (the bug off).
    * `model` - the model the engine drives the system with.
    * `adapter` - the engine's connector between the model and the system.
    * `minimum` - the smallest failing plan, a list of plain maps. Each map
      has a `:command` key holding the command name as an atom, plus the
      command's fields. A field holding a generated identifier is written
      as `:id`. With `nil` the entry is a regression entry: it has no
      hand-written smallest plan and records what the engine does on its seed
      set. Its rows still count a seed as found when a failing run fired the
      seeded bug, but `reached_minimum?` is always false, the printed table
      shows `-` in the reached-minimum cell, and a run that finds nothing does
      not fail the task.
    * `compare` - how a shrunk plan is matched against `minimum`: `:exact`,
      `:ignore_ids` (drop every field whose value is `:id`) or
      `{:ignore_fields, [atom]}` (drop the named fields).
    * `seeds` - the seed list the entry runs over.
    * `max_commands` - the longest plan the model draws.
    * `plan_cap` - when set, a positive integer that replaces the `--cap`
      option for this entry. A regression entry uses it to pin the budget its
      seed set was recorded under.
    * `run_opts` - a keyword list of extra options for the engine's run.
      `PropertyDamage.Corpus.Engine.Next` passes it to
      `PropertyDamage.Next.run/1`; `PropertyDamage.Corpus.Engine.Run`
      ignores it. Default `[]`.
    * `expect` - makes the entry a guardrail entry: a model that commits one
      mistake PD must catch. `{:raises, Module}` expects the run to raise an
      exception of that module; `{:report, text}` expects a line of
      `PropertyDamage.Next.Report.format/1` that contains `text`. A seed
      counts as found when that happens, and the exception message or the
      report line is printed under the table. The entry needs no `minimum`.
      Only `PropertyDamage.Corpus.Engine.Next` reads it. Default `nil`.
    * `control` - for a guardrail entry, a keyword list with `:model` and
      `:adapter`, the corrected pair the bug-off run uses. The `bug` switch
      then reads as: on, the mistake is present; off, the corrected pair runs
      and must pass. Default `nil`.
    * `skip` - a reason string. A skipped entry is never run: the table shows
      `skipped: <reason>` for it and the saved table records the reason. It
      needs no other field than `name`.
  """

  @type compare :: :exact | :ignore_ids | {:ignore_fields, [atom()]}

  @type t :: %__MODULE__{
          name: String.t(),
          engine: module() | nil,
          system: module() | nil,
          bug: atom() | nil,
          model: module() | nil,
          adapter: module() | nil,
          minimum: [map()] | nil,
          compare: compare(),
          seeds: [integer()],
          max_commands: pos_integer(),
          plan_cap: pos_integer() | nil,
          run_opts: keyword(),
          expect: {:raises, module()} | {:report, String.t()} | nil,
          control: [model: module(), adapter: module()] | nil,
          skip: String.t() | nil
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    :engine,
    :system,
    :bug,
    :model,
    :adapter,
    :minimum,
    :plan_cap,
    :skip,
    :expect,
    :control,
    compare: :ignore_ids,
    seeds: Enum.to_list(1..20),
    max_commands: 20,
    run_opts: []
  ]
end
