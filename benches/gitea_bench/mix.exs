defmodule GiteaBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :gitea_bench,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: false,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp deps do
    [
      {:property_damage, path: "../.."},
      {:playwright, "~> 1.49.1-alpha.2"},
      {:req, "~> 0.5"},
      # P9 webhook demo: a tiny HTTP listener that receives Gitea's issues
      # webhook and pushes it into the run's EventQueue.
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.16"}
    ]
  end

  # Friction-free infra lifecycle, mirroring the redis/oban benches. `mix test`
  # brings up two dedicated, ephemeral Gitea instances (idempotent: a no-op when
  # already healthy) and creates a known admin on each, then runs. The API
  # adapter drives one instance and the Playwright UI adapter drives the other,
  # so the differential oracle compares two transports without cross-contamination.
  #
  # Tear down explicitly with `mix bench.db.down`. If PD_GITEA_API_URL and
  # PD_GITEA_UI_URL are set (e.g. CI service containers / BYO), the container
  # step is skipped and the bench points at those endpoints instead.
  #
  # `playwright.install` fetches the Chromium browser the UI adapter drives; it
  # is idempotent and cheap once cached.
  defp aliases do
    [
      "bench.db.up": ["cmd ./scripts/bench_up.sh"],
      "bench.db.down": ["cmd docker compose down -v"],
      # Install only the Chromium binary via the driver bundled with the
      # `playwright` hex package (no `--with-deps`, so no root needed). Idempotent
      # and cached under ~/.cache/ms-playwright.
      "playwright.install": [
        "cmd node deps/playwright/priv/static/driver.js install chromium"
      ],
      test: ["bench.db.up", "playwright.install", "test"]
    ]
  end
end
