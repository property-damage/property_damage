defmodule PropertyDamage.MixProject do
  use Mix.Project

  @version "0.2.0"
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
      # :inets provides :httpc, which the built-in network nemeses use to drive
      # the Toxiproxy control API; :ssl is listed so its modules (public_key et
      # al.) are on the code path, since httpc computes SSL verify defaults when
      # building request options even for a plain-HTTP request.
      extra_applications: [:logger, :inets, :ssl]
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
        "guides/scaffolding.md",
        "guides/deterministic_generation.md",
        "guides/writing_invariants.md",
        "guides/coverage_and_catalogs.md",
        "guides/debugging_failures.md",
        "guides/async_and_eventual_consistency.md",
        "guides/resource_polling.md",
        "guides/idempotency_testing.md",
        "guides/parallel_testing.md",
        "guides/chaos_engineering.md",
        "guides/mocking_third_parties.md",
        "guides/contract_testing_with_shared_libraries.md",
        "guides/differential_testing.md",
        "guides/dual_transport_testing.md",
        "guides/integration_testing.md",
        "guides/reusable_components.md",
        "guides/static_regression_tests.md",
        "guides/performance_tuning.md",
        "guides/load_testing.md",
        "guides/mutation_testing.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        # Matched first: keep the deferred load-testing and mutation-testing
        # guides out of the main Guides group so they are not advertised
        # alongside the validated surface.
        "Advanced (deferred)": ~r/guides\/(load_testing|mutation_testing)/,
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        "Core Behaviours": [
          PropertyDamage.Command,
          PropertyDamage.Model,
          PropertyDamage.Model.Projection,
          PropertyDamage.Model.Projection.Liveness,
          PropertyDamage.Model.Projection.Statistics,
          PropertyDamage.Model.Simulator,
          PropertyDamage.Adapter,
          PropertyDamage.Adapter.Injector,
          PropertyDamage.Nemesis
        ],
        Generation: [
          PropertyDamage.External,
          PropertyDamage.ExternalMarker,
          PropertyDamage.Generator,
          PropertyDamage.Sequence
        ],
        Execution: [
          PropertyDamage.Executor,
          PropertyDamage.Linearization,
          PropertyDamage.Settle,
          PropertyDamage.EventQueue,
          PropertyDamage.EventLog.Entry,
          PropertyDamage.ResourcePoller,
          PropertyDamage.Stutter,
          PropertyDamage.Stutter.Config,
          PropertyDamage.Stutter.Violation
        ],
        Shrinking: [
          PropertyDamage.Shrinker,
          PropertyDamage.Shrinker.Config
        ],
        "Fault Injection": [
          PropertyDamage.Nemesis.NetworkLatency,
          PropertyDamage.Nemesis.NetworkPartition,
          PropertyDamage.Nemesis.PacketLoss
        ],
        "Diagnostics & Reporting": [
          PropertyDamage.FailureReport,
          PropertyDamage.Analysis,
          PropertyDamage.Replay,
          PropertyDamage.Coverage,
          PropertyDamage.Diagram,
          PropertyDamage.RunTrace,
          PropertyDamage.RunTrace.Step,
          PropertyDamage.RunComparison,
          PropertyDamage.RunComparison.Html,
          PropertyDamage.Telemetry,
          PropertyDamage.Progress,
          PropertyDamage.Progress.RunUpdate,
          PropertyDamage.Progress.RunResult,
          PropertyDamage.Progress.ReplayUpdate,
          PropertyDamage.Progress.LoadUpdate,
          PropertyDamage.Progress.LoadResult,
          PropertyDamage.Progress.MutationUpdate,
          PropertyDamage.Progress.MutationResult,
          PropertyDamage.Progress.DifferentialUpdate,
          PropertyDamage.Progress.DifferentialResult
        ],
        Export: [
          PropertyDamage.Export,
          PropertyDamage.Export.HTTPSpec,
          PropertyDamage.Export.Script
        ],
        Differential: [
          PropertyDamage.Differential,
          PropertyDamage.Differential.Result
        ],
        "Persistence & Regression": [
          PropertyDamage.Persistence,
          PropertyDamage.SeedLibrary,
          PropertyDamage.Regression
        ],
        "Test Integration": [
          PropertyDamage.ExUnit,
          PropertyDamage.IEx
        ],
        Mocking: [
          PropertyDamage.MockServiceAdapter,
          PropertyDamage.MockServiceRegistry
        ],
        Exceptions: [
          PropertyDamage.Error,
          PropertyDamage.ErrorOrigin,
          PropertyDamage.AssertionFailed,
          PropertyDamage.CommandTimeoutError,
          PropertyDamage.ProjectionError
        ],
        # Modules that ship but are work in progress and not fully supported at
        # this time (see the README note). Grouped last and clearly labelled so
        # the docs do not advertise them alongside the validated core.
        "Advanced (work in progress, not fully supported)": [
          PropertyDamage.Flakiness,
          PropertyDamage.Mutation,
          PropertyDamage.Mutation.Report,
          PropertyDamage.Mutation.Analysis,
          PropertyDamage.Suggestions,
          PropertyDamage.Suggestions.Patterns,
          PropertyDamage.FailureIntelligence,
          PropertyDamage.FailureIntelligence.Fingerprint,
          PropertyDamage.FailureIntelligence.Patterns,
          PropertyDamage.FailureIntelligence.Similarity,
          PropertyDamage.FailureIntelligence.Verification,
          PropertyDamage.LoadTest,
          PropertyDamage.Forensics,
          PropertyDamage.Integration,
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
