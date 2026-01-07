defmodule PropertyDamage.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/property-damage/property_damage"

  def project do
    [
      app: :property_damage,
      version: @version,
      elixir: "~> 1.14",
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
      {:jason, "~> 1.4", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "PropertyDamage",
      extras: [
        "README.md",
        "guides/getting_started.md",
        "guides/writing_invariants.md",
        "guides/debugging_failures.md",
        "guides/chaos_engineering.md",
        "guides/integration_testing.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        "Core Behaviours": [
          PropertyDamage.Command,
          PropertyDamage.Model,
          PropertyDamage.Adapter,
          PropertyDamage.Projection,
          PropertyDamage.Nemesis
        ],
        Execution: [
          PropertyDamage.Executor,
          PropertyDamage.Linearization,
          PropertyDamage.EventQueue,
          PropertyDamage.Ref
        ],
        "Shrinking & Analysis": [
          PropertyDamage.Shrinker,
          PropertyDamage.Analysis,
          PropertyDamage.Replay,
          PropertyDamage.Coverage,
          PropertyDamage.Flakiness
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
        "Testing Tools": [
          PropertyDamage.Mutation,
          PropertyDamage.Suggestions,
          PropertyDamage.FailureIntelligence,
          PropertyDamage.LoadTest
        ],
        "Debugging & Export": [
          PropertyDamage.Diagram,
          PropertyDamage.Diff,
          PropertyDamage.Export,
          PropertyDamage.Forensics
        ],
        Integration: [
          PropertyDamage.Integration,
          PropertyDamage.Livebook,
          PropertyDamage.Livebook.Charts,
          PropertyDamage.Telemetry,
          PropertyDamage.Telemetry.Collector,
          PropertyDamage.Telemetry.Dashboard
        ],
        Persistence: [
          PropertyDamage.Persistence,
          PropertyDamage.SeedLibrary,
          PropertyDamage.Regression
        ]
      ],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
