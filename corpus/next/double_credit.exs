# A refund whose response is lost, then retried without its idempotency key,
# is credited twice. With payments from 1 and refunds from 1, the smallest
# failing plan pays 1, then refunds 1 with the response lost. A layer adds
# the lost response as an assign beside the refund; the model never reads
# it, and the adapter's port acknowledges it.
%PropertyDamage.Corpus.Entry{
  name: "double_credit",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Scheme,
  bug: :double_credit,
  model: Corpus.Next.Scheme.FaultModel,
  adapter: Corpus.Next.Scheme.FaultAdapter,
  minimum: [
    %{command: :pay, amount: 1},
    %{command: :refund, payment_id: :id, amount: 1, lose_response: true}
  ],
  compare: :ignore_ids,
  max_commands: 8
}
