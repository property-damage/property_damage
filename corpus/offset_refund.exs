# A refund of exactly one less than the payment's amount is accepted but its
# credit is never applied. The refund amount is drawn from 1 up to the payment,
# so the failing value sits inside the range, not on a bound. The smallest
# failing plan pays 2, then refunds 1.
%PropertyDamage.Corpus.Entry{
  name: "offset_refund",
  engine: PropertyDamage.Corpus.Engine.Run,
  system: Corpus.Scheme,
  bug: :offset_refund,
  model: Corpus.Scheme.RangeModel,
  adapter: Corpus.Scheme.Adapter,
  minimum: [
    %{command: :pay, amount: 2},
    %{command: :refund, payment_id: :id, amount: 1, lose_response: false}
  ],
  compare: :ignore_ids,
  max_commands: 8
}
