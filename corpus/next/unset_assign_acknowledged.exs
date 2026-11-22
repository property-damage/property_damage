# A port acknowledges an assign no spec sets. The run must raise at the call.
# The bug switch on keeps the port that acknowledges at every refund; off runs
# the port that acknowledges only when the assign is set.
%PropertyDamage.Corpus.Entry{
  name: "unset_assign_acknowledged",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Scheme,
  bug: :ack_unset_assign,
  model: Corpus.Next.Scheme.RefundModel,
  adapter: Corpus.Next.Guardrail.AckEveryRefundAdapter,
  expect: {:raises, PropertyDamage.Next.AcknowledgedUnsetAssignError},
  control: [model: Corpus.Next.Scheme.RefundModel, adapter: Corpus.Next.Scheme.FaultAdapter],
  max_commands: 8
}
