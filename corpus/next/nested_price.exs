# A refund carries a nested price, a map of an amount and a currency. The
# amount is drawn within the payment's balance, so it depends on earlier state.
# In the alternate currency the system rounds the converted amount up instead
# of down: an odd amount converts one unit too high, and a refund whose rounded
# conversion exceeds the balance is rejected. The smallest failing plan pays 1,
# then refunds a price of 1 in the alternate currency (converted 1, rounded
# to 2, over the balance). This entry runs the bug on the new engine; its
# model is a port of the default corpus directory's entry of the same name.
%PropertyDamage.Corpus.Entry{
  name: "nested_price",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Pricing,
  bug: :nested_price,
  model: Corpus.Next.Pricing.Model,
  adapter: Corpus.Next.Pricing.Adapter,
  minimum: [
    %{command: :pay, amount: 1},
    %{command: :refund, payment_id: :id, price: %{amount: 1, currency: :alt}}
  ],
  compare: :ignore_ids,
  max_commands: 8
}
