# A set with an empty string value is rejected by the store, while the model
# predicts success. The smallest failing plan is one set of any key to "".
%PropertyDamage.Corpus.Entry{
  name: "rejected_set",
  engine: PropertyDamage.Corpus.Engine.Run,
  system: Corpus.KeyValue,
  bug: :rejected_set,
  model: Corpus.KeyValue.Model,
  adapter: Corpus.KeyValue.Adapter,
  minimum: [%{command: :set, key: "k0", value: ""}],
  compare: {:ignore_fields, [:key]},
  max_commands: 8
}
