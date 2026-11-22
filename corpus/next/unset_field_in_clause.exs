# An adapter clause matches a field name the layer never sets, so the clause
# never runs. The run must fail naming the unacknowledged assign. The bug
# switch on keeps the misspelled clause; off runs the corrected adapter.
%PropertyDamage.Corpus.Entry{
  name: "unset_field_in_clause",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Scheme,
  bug: :misspelled_assign,
  model: Corpus.Next.Scheme.FaultModel,
  adapter: Corpus.Next.Guardrail.MisspelledAssignAdapter,
  expect: {:report, "acknowledged 0"},
  control: [model: Corpus.Next.Scheme.FaultModel, adapter: Corpus.Next.Scheme.FaultAdapter],
  max_commands: 8
}
