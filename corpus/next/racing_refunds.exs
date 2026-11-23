# Two overlapping refunds both pass the check that a refund stays below its
# payment. The smallest failing plan pays 1, then refunds 1 of it in each of
# two lanes, interleaved so that both checks run before either refund applies.
%PropertyDamage.Corpus.Entry{
  name: "racing_refunds",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Scheme,
  bug: :racing_refunds,
  model: Corpus.Next.Scheme.RaceModel,
  adapter: Corpus.Next.Scheme.RaceAdapter,
  minimum: [
    %{command: :pay, amount: 1},
    %{command: :refund, payment_id: :id, amount: 1, lane: 1},
    %{command: :refund, payment_id: :id, amount: 1, lane: 2}
  ],
  compare: :ignore_ids,
  max_commands: 4,
  run_opts: [lanes: 2, lane_steps: 3, yields: 1]
}
