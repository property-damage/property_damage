defmodule PropertyDamage.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/property-damage/property_damage"

  def project do
    [
      app: :property_damage,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Docs
      name: "PropertyDamage",
      description: "A stateful property-based testing framework for Elixir",
      source_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:stream_data, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:nimble_options, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "PropertyDamage",
      extras: [
        "README.md",
        "guides/getting_started.md",
        "guides/quickstart.md",
        "guides/cheatsheet.md",
        "guides/writing_commands.md",
        "guides/writing_invariants.md",
        "guides/debugging_failures.md",
        "guides/async_and_eventual_consistency.md",
        "guides/resource_polling.md",
        "guides/idempotency_testing.md",
        "guides/parallel_testing.md",
        "guides/chaos_engineering.md",
        "guides/mocking_third_parties.md",
        "guides/contract_testing_with_shared_libraries.md",
        "guides/differential_testing.md",
        "guides/integration_testing.md",
        "guides/reusable_components.md",
        "guides/static_regression_tests.md",
        "guides/performance_tuning.md",
        "guides/load_testing.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        # Matched first: keep the deferred load-testing guide out of the main
        # Guides group so it is not advertised alongside the validated surface.
        "Advanced (deferred)": ~r/guides\/load_testing/,
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        "Core Behaviours": [
          PropertyDamage.Command,
          PropertyDamage.Model,
          PropertyDamage.Model.Projection,
          PropertyDamage.Model.Simulator,
          PropertyDamage.Adapter,
          PropertyDamage.Adapter.Injector,
          PropertyDamage.Nemesis
        ],
        Execution: [
          PropertyDamage.Executor,
          PropertyDamage.Linearization,
          PropertyDamage.Settle,
          PropertyDamage.EventQueue,
          PropertyDamage.Ref
        ],
        Shrinking: [
          PropertyDamage.Shrinker
        ],
        "Fault Injection": [
          PropertyDamage.Nemesis.NetworkLatency,
          PropertyDamage.Nemesis.NetworkPartition,
          PropertyDamage.Nemesis.PacketLoss,
          PropertyDamage.Nemesis.MemoryPressure,
          PropertyDamage.Nemesis.CPUStress,
          PropertyDamage.Nemesis.ClockSkew,
          PropertyDamage.Nemesis.ProcessKill,
          PropertyDamage.Nemesis.SlowIO,
          PropertyDamage.Nemesis.ResourceExhaustion,
          PropertyDamage.Nemesis.CertificateExpiry
        ],
        "Diagnostics & Reporting": [
          PropertyDamage.FailureReport,
          PropertyDamage.Replay,
          PropertyDamage.Coverage,
          PropertyDamage.Diagram,
          PropertyDamage.Diff,
          PropertyDamage.Telemetry
        ],
        Export: [
          PropertyDamage.Export
        ],
        Differential: [
          PropertyDamage.Differential
        ],
        "Persistence & Regression": [
          PropertyDamage.Persistence,
          PropertyDamage.SeedLibrary,
          PropertyDamage.Regression
        ],
        # Modules that ship but are NOT part of the v0.1 validated surface
        # (see the README note). Grouped last and clearly labelled so the docs
        # do not advertise them alongside the validated core.
        "Advanced (not in v0.1 surface)": [
          PropertyDamage.Analysis,
          PropertyDamage.Flakiness,
          PropertyDamage.Mutation,
          PropertyDamage.Suggestions,
          PropertyDamage.FailureIntelligence,
          PropertyDamage.LoadTest,
          PropertyDamage.Forensics,
          PropertyDamage.Integration,
          PropertyDamage.Livebook,
          PropertyDamage.Livebook.Charts,
          PropertyDamage.Telemetry.Collector,
          PropertyDamage.Telemetry.Dashboard
        ]
      ],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end
end
