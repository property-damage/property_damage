# A set with an empty string value is rejected by the store, while the model
# predicts success. The smallest failing plan is one set of any key to "".
# This entry runs the bug on the new engine; its model is a port of the
# default corpus directory's entry of the same name.
%PropertyDamage.Corpus.Entry{
  name: "rejected_set",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.KeyValue,
  bug: :rejected_set,
  model: Corpus.Next.KeyValue.Model,
  adapter: Corpus.Next.KeyValue.Adapter,
  minimum: [%{command: :set, key: "k0", value: ""}],
  compare: {:ignore_fields, [:key]},
  max_commands: 8
}
