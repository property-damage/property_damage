# A refund that empties a payment above 100 is accepted but never credited.
# The smallest failing plan pays 101, then refunds all 101 of it.
%PropertyDamage.Corpus.Entry{
  name: "lost_full_refund",
  engine: PropertyDamage.Corpus.Engine.Run,
  system: Corpus.Scheme,
  bug: :lost_full_refund,
  model: Corpus.Scheme.RefundModel,
  adapter: Corpus.Scheme.Adapter,
  minimum: [
    %{command: :pay, amount: 101},
    %{command: :refund, payment_id: :id, amount: 101, lose_response: false}
  ],
  compare: :ignore_ids,
  max_commands: 8
}
