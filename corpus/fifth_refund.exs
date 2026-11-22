# The fifth refund of one payment is accepted but its credit is never applied.
# The smallest failing plan pays 5, then refunds 1 of it five times.
%PropertyDamage.Corpus.Entry{
  name: "fifth_refund",
  engine: PropertyDamage.Corpus.Engine.Run,
  system: Corpus.Scheme,
  bug: :fifth_refund,
  model: Corpus.Scheme.DepthModel,
  adapter: Corpus.Scheme.Adapter,
  minimum: [
    %{command: :pay, amount: 5},
    %{command: :refund, payment_id: :id, amount: 1, lose_response: false},
    %{command: :refund, payment_id: :id, amount: 1, lose_response: false},
    %{command: :refund, payment_id: :id, amount: 1, lose_response: false},
    %{command: :refund, payment_id: :id, amount: 1, lose_response: false},
    %{command: :refund, payment_id: :id, amount: 1, lose_response: false}
  ],
  compare: :ignore_ids,
  max_commands: 12
}
