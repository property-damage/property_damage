# A refund that empties a payment above 100 is accepted but never credited.
# The smallest failing plan pays 101, then refunds all 101 of it. This entry
# runs the bug on the new engine; its model is a port of the default corpus
# directory's entry of the same name.
%PropertyDamage.Corpus.Entry{
  name: "lost_full_refund",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Scheme,
  bug: :lost_full_refund,
  model: Corpus.Next.Scheme.RefundModel,
  adapter: Corpus.Next.Scheme.Adapter,
  minimum: [
    %{command: :pay, amount: 101},
    %{command: :refund, payment_id: :id, amount: 101}
  ],
  compare: :ignore_ids,
  max_commands: 8
}
