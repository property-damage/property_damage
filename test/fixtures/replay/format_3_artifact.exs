# PropertyDamage replay artifact, format 3
# model: PropertyDamage.Test.ReplayFixtures.ExternalModel
# seed: 4
# run: 1 (the run this seed generates)
# target "ref" (reference), expansion: :random
# target "second", expansion: :random
%{
  choices: %{
    "ref" => [
      # root 0: Open (not expanded)
      %{
        aliases: %{},
        commands: [%PropertyDamage.Test.ReplayFixtures.Open{label: 0}],
        entry: nil,
        root_id: 0
      },
      # root 1: Refund[0] = [Refund]
      %{
        aliases: %{},
        commands: [
          %PropertyDamage.Test.ReplayFixtures.Refund{
            account_id: %PropertyDamage.Placeholder{
              event_index: 0,
              event_module: PropertyDamage.Test.ReplayFixtures.Opened,
              id: {%PropertyDamage.Sequence.Position{offset: 0, section: :prefix}, 0, [:id]},
              path: [:id],
              position: %PropertyDamage.Sequence.Position{offset: 0, section: :prefix},
              resolved: nil
            },
            amount: 0
          }
        ],
        entry: "Refund[0]",
        root_id: 1
      }
    ],
    "second" => [
      # root 0: Open (not expanded)
      %{
        aliases: %{},
        commands: [%PropertyDamage.Test.ReplayFixtures.Open{label: 0}],
        entry: nil,
        root_id: 0
      },
      # root 1: Refund[1] = [Credit, Credit]
      %{
        aliases: %{},
        commands: [
          %PropertyDamage.Test.ReplayFixtures.Credit{
            account_id: %PropertyDamage.Placeholder{
              event_index: 0,
              event_module: PropertyDamage.Test.ReplayFixtures.Opened,
              id: {%PropertyDamage.Sequence.Position{offset: 0, section: :prefix}, 0, [:id]},
              path: [:id],
              position: %PropertyDamage.Sequence.Position{offset: 0, section: :prefix},
              resolved: nil
            },
            amount: 0,
            part: 0
          },
          %PropertyDamage.Test.ReplayFixtures.Credit{
            account_id: %PropertyDamage.Placeholder{
              event_index: 0,
              event_module: PropertyDamage.Test.ReplayFixtures.Opened,
              id: {%PropertyDamage.Sequence.Position{offset: 0, section: :prefix}, 0, [:id]},
              path: [:id],
              position: %PropertyDamage.Sequence.Position{offset: 0, section: :prefix},
              resolved: nil
            },
            amount: 0,
            part: 1
          }
        ],
        entry: "Refund[1]",
        root_id: 1
      }
    ]
  },
  external_markers: [],
  failure: %{
    root_index: 1,
    signature: {:diverged, {PropertyDamage.Test.ReplayFixtures.Tally, :total}, 1}
  },
  format: 3,
  model: PropertyDamage.Test.ReplayFixtures.ExternalModel,
  prefix: [],
  roots: [
    # root 0: Open
    %{command: %PropertyDamage.Test.ReplayFixtures.Open{label: 0}, root_id: 0},
    # root 1: Refund
    %{
      command: %PropertyDamage.Test.ReplayFixtures.Refund{
        account_id: %PropertyDamage.Placeholder{
          event_index: 0,
          event_module: PropertyDamage.Test.ReplayFixtures.Opened,
          id: {%PropertyDamage.Sequence.Position{offset: 0, section: :prefix}, 0, [:id]},
          path: [:id],
          position: %PropertyDamage.Sequence.Position{offset: 0, section: :prefix},
          resolved: nil
        },
        amount: 0
      },
      root_id: 1
    }
  ],
  run: 1,
  seed: 4,
  targets: [%{expansion: :random, name: "ref"}, %{expansion: :random, name: "second"}]
}
