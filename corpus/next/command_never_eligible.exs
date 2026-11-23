# The model drops the command that a later command depends on. The report
# must list the dependent command as never eligible. The bug switch on keeps
# the model without the pay command; off runs the model that has it.
%PropertyDamage.Corpus.Entry{
  name: "command_never_eligible",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Scheme,
  bug: :dropped_command,
  model: Corpus.Next.Guardrail.NoPayModel,
  adapter: Corpus.Next.Scheme.FaultAdapter,
  expect: {:report, "never eligible"},
  control: [model: Corpus.Next.Scheme.RefundModel, adapter: Corpus.Next.Scheme.FaultAdapter],
  max_commands: 8
}
