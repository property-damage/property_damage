# A delete answers success and changes nothing, so a later read returns the
# value that should be gone. This is a regression entry: it has no hand-written
# smallest plan and records what the engine does on a fixed seed set, with a
# budget of two plans per seed. Some of those seeds draw no put, delete, read
# of one key in two plans and pass.
%PropertyDamage.Corpus.Entry{
  name: "store",
  engine: PropertyDamage.Corpus.Engine.Run,
  system: Corpus.Store,
  bug: :noop_delete,
  model: Corpus.Store.Model,
  adapter: Corpus.Store.Adapter,
  minimum: nil,
  seeds: Enum.to_list(1..24),
  plan_cap: 2,
  max_commands: 16
}
