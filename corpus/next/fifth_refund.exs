# The fifth refund of one payment is accepted but its credit is never applied.
# The smallest failing plan pays 5, then refunds 1 of it five times. This
# entry runs the bug on the new engine; its model is a port of the default
# corpus directory's entry of the same name.
%PropertyDamage.Corpus.Entry{
  name: "fifth_refund",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Scheme,
  bug: :fifth_refund,
  model: Corpus.Next.Scheme.DepthModel,
  adapter: Corpus.Next.Scheme.Adapter,
  minimum: [
    %{command: :pay, amount: 5},
    %{command: :refund, payment_id: :id, amount: 1},
    %{command: :refund, payment_id: :id, amount: 1},
    %{command: :refund, payment_id: :id, amount: 1},
    %{command: :refund, payment_id: :id, amount: 1},
    %{command: :refund, payment_id: :id, amount: 1}
  ],
  compare: :ignore_ids,
  max_commands: 12
}
