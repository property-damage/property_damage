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
    compare: :ignore_ids,
    seeds: Enum.to_list(1..20),
    max_commands: 20
  ]
end
