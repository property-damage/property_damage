# A refund of a payment that already had a refund is credited one unit short,
# so a refund split in two credits less than the same refund made once. No
# check on one execution sees it: the model compares the balances the scheme
# reported between a run of each plan with every refund whole and a run with
# some refunds split. The smallest failing plan pays 2, then refunds 2 as a
# refund of 1 followed by a refund of 1.
%PropertyDamage.Corpus.Entry{
  name: "split_refund",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Scheme,
  bug: :split_refund,
  model: Corpus.Next.Scheme.SplitModel,
  adapter: Corpus.Next.Scheme.Adapter,
  minimum: [
    %{command: :pay, amount: 2},
    %{
      command: :refund,
      payment_id: :id,
      amount: 2,
      path: [
        %{command: :refund, payment_id: :id, amount: 1},
        %{command: :refund, payment_id: :id, amount: 1}
      ]
    }
  ],
  compare: :ignore_ids,
  max_commands: 8
}
