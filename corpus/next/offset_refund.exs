# A refund of exactly one less than the payment's amount is accepted but its
# credit is never applied. The refund amount is drawn from 1 up to the payment,
# so the failing value sits inside the range, not on a bound. The smallest
# failing plan pays 2, then refunds 1. This entry runs the bug on the new
# engine; its model is a port of the default corpus directory's entry of the
# same name.
%PropertyDamage.Corpus.Entry{
  name: "offset_refund",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Scheme,
  bug: :offset_refund,
  model: Corpus.Next.Scheme.RangeModel,
  adapter: Corpus.Next.Scheme.Adapter,
  minimum: [
    %{command: :pay, amount: 2},
    %{command: :refund, payment_id: :id, amount: 1}
  ],
  compare: :ignore_ids,
  max_commands: 8
}
