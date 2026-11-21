# A refund whose response is lost, then retried without its idempotency key,
# is credited twice. With payments from 1 and refunds from 1, the smallest
# failing plan pays 1, then refunds 1 with the response lost.
%PropertyDamage.Corpus.Entry{
  name: "double_credit",
  engine: PropertyDamage.Corpus.Engine.Run,
  system: Corpus.Scheme,
  bug: :double_credit,
  model: Corpus.Scheme.RetryModel,
  adapter: Corpus.Scheme.Adapter,
  minimum: [
    %{command: :pay, amount: 1},
    %{command: :refund, payment_id: :id, amount: 1, lose_response: true}
  ],
  compare: :ignore_ids,
  max_commands: 8
}
