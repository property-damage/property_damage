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
      as `:id`.
    * `compare` - how a shrunk plan is matched against `minimum`: `:exact`,
      `:ignore_ids` (drop every field whose value is `:id`) or
      `{:ignore_fields, [atom]}` (drop the named fields).
    * `seeds` - the seed list the entry runs over.
    * `max_commands` - the longest plan the model draws.
  """

  @type compare :: :exact | :ignore_ids | {:ignore_fields, [atom()]}

  @type t :: %__MODULE__{
          name: String.t(),
          engine: module(),
          system: module(),
          bug: atom() | nil,
          model: module(),
          adapter: module(),
          minimum: [map()],
          compare: compare(),
          seeds: [integer()],
          max_commands: pos_integer()
        }

  @enforce_keys [:name, :engine, :system, :bug, :model, :adapter, :minimum]
  defstruct [
    :name,
    :engine,
    :system,
    :bug,
    :model,
    :adapter,
    :minimum,
    compare: :ignore_ids,
    seeds: Enum.to_list(1..20),
    max_commands: 20
  ]
end
