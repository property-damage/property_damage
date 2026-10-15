# PropertyDamage replay artifact, format 1
# model: CachexBench.Model
# seed: 3
# run: 1 (the run this seed generates)
# target "cachex" (reference), expansion: :random
# target "second", expansion: :random
%{
  choices: %{
    "cachex" => [
      # root 0: Incr[0] = [Incr]
      %{
        aliases: %{},
        commands: [%CachexBench.Commands.Incr{amount: 3, key: :alpha}],
        entry: "Incr[0]",
        root_id: 12
      }
    ],
    "second" => [
      # root 0: Incr[1] = [Incr, Incr]
      %{
        aliases: %{},
        commands: [
          %CachexBench.Commands.Incr{amount: 1, key: :alpha},
          %CachexBench.Commands.Incr{amount: 2, key: :alpha}
        ],
        entry: "Incr[1]",
        root_id: 12
      }
    ]
  },
  failure: %{
    kind: :diverged,
    name: {CachexBench.Projection, :expected_contents},
    root_index: 0,
    variant_index: 1
  },
  format: 1,
  model: CachexBench.Model,
  prefix: [],
  roots: [
    # root 0: Incr
    %{command: %CachexBench.Commands.Incr{amount: 3, key: :alpha}, root_id: 12}
  ],
  run: 1,
  seed: 3,
  targets: [%{expansion: :random, name: "cachex"}, %{expansion: :random, name: "second"}]
}
