# A withdrawal of 12 or more debits twice its amount, so the reported balance
# drifts from the ledger. This is a regression entry: it has no hand-written
# smallest plan and records what the new engine does on a fixed seed set, with
# a budget of two plans per seed. Some of those seeds draw no large withdrawal
# in two plans and pass. Its model is a port of the default corpus directory's
# entry of the same name.
%PropertyDamage.Corpus.Entry{
  name: "ledger",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Ledger,
  bug: :double_debit_from_12,
  model: Corpus.Next.Ledger.Model,
  adapter: Corpus.Next.Ledger.Adapter,
  minimum: nil,
  seeds: Enum.to_list(1..20) ++ [24, 33, 39, 40],
  plan_cap: 2,
  max_commands: 10
}
