defmodule PropertyDamage.FailureIntelligence.Verification do
  @moduledoc """
  Fix verification: replays the shrunk sequence of a failure report and says
  whether the same failure still occurs.

  The replay artifact of the report (its `replay` field) holds the shrunk
  commands, the targets and the signature of the failure
  (`PropertyDamage.Failure.signature/2`). Verification runs those commands
  through `PropertyDamage.run(only: [replay: path])` and compares the
  signature of what happens with the recorded one. It never draws a plan from
  a seed, so a change to generation cannot hide a failing sequence.

  A report with no replay artifact cannot be verified. Neighbouring seeds are
  a separate question, answered by
  `PropertyDamage.FailureIntelligence.Exploration`.
  """

  alias PropertyDamage.{Campaign, Failure, FailureReport, Options, ReplayArtifact, Target}

  @type status :: :verified | :still_failing | :different_failure

  @type verification_result :: %{
          required(:status) => status(),
          required(:signature) => Failure.signature(),
          required(:failure) => FailureReport.t() | nil,
          required(:summary) => String.t(),
          optional(:new_signature) => Failure.signature()
        }

  @type options :: [targets: [module() | {module(), keyword()}]]

  @doc """
  Verifies a fix by replaying the shrunk sequence of `report` against the
  fixed system.

  Returns a map whose `:status` is one of:

  - `:verified`: the replay runs to completion with no failure.
  - `:still_failing`: a failure with the recorded signature recurs.
  - `:different_failure`: a failure with another signature occurs. The map
    carries it as `:new_signature`.

  Every result carries `:signature` (the recorded one), `:failure` (the report
  of the recurring or new failure, `nil` when verified) and a one-line
  `:summary`.

  Returns `{:error, :no_replay_artifact}` when `report.replay` is `nil` or
  `{:refused, _}`. A setup problem, such as a model or targets that do not
  match the artifact, raises as `PropertyDamage.run/1` does.

  ## Options

  - `:targets` - A list with exactly one entry (required): the adapter to
    replay against, as a module or `{AdapterModule, config: map, ...}`; see
    `PropertyDamage.Target`. Its name must match the target the artifact
    records.
  """
  @spec verify_fix(FailureReport.t(), module(), options()) ::
          verification_result() | {:error, :no_replay_artifact}
  def verify_fix(%FailureReport{replay: %{failure: %{signature: signature}} = term}, model, opts)
      when is_map(term) do
    target = Options.required_target!(opts)

    case replay(term, model, target) do
      {:ok, _stats} ->
        %{
          status: :verified,
          signature: signature,
          failure: nil,
          summary: "Fix verified. The shrunk sequence replays without a failure."
        }

      {:error, %FailureReport{} = failure} ->
        failed(signature, failure)
    end
  end

  def verify_fix(%FailureReport{}, _model, _opts), do: {:error, :no_replay_artifact}

  @doc """
  Verifies several fixes, one report at a time.

  Returns `[{report, result_or_error}]`, each element the outcome of
  `verify_fix/3` for that report. To verify a cluster of failures, pass the
  reports of its members.
  """
  @spec verify_fixes([FailureReport.t()], module(), options()) :: [
          {FailureReport.t(), verification_result() | {:error, :no_replay_artifact}}
        ]
  def verify_fixes(reports, model, opts \\ []) do
    Enum.map(reports, fn report -> {report, verify_fix(report, model, opts)} end)
  end

  @doc """
  Formats a verification result for display.
  """
  @spec format_result(verification_result()) :: String.t()
  def format_result(%{status: status} = result) do
    icon =
      case status do
        :verified -> "✓"
        :still_failing -> "✗"
        :different_failure -> "⚠"
      end

    """
    #{icon} Verification Result: #{status}
    ─────────────────────────────────────────────
    Recorded failure: #{inspect(result.signature)}
    #{new_signature_line(result)}
    #{result.summary}
    """
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp new_signature_line(%{new_signature: new_signature}),
    do: "New failure: #{inspect(new_signature)}\n"

  defp new_signature_line(_result), do: ""

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp failed(signature, %FailureReport{} = failure) do
    case Failure.signature(failure.failure_reason, variant_index(failure)) do
      ^signature ->
        %{
          status: :still_failing,
          signature: signature,
          failure: failure,
          summary: "Fix NOT verified. The recorded failure still occurs."
        }

      new_signature ->
        %{
          status: :different_failure,
          signature: signature,
          new_signature: new_signature,
          failure: failure,
          summary:
            "Fix NOT verified. The recorded failure is gone, but the sequence now fails " <>
              "with another failure."
        }
    end
  end

  defp variant_index(%FailureReport{variant: %{index: index}}), do: index
  defp variant_index(%FailureReport{}), do: 0

  # Replays the artifact from a fresh temporary directory, removed afterwards.
  defp replay(term, model, %Target{} = target) do
    dir = Path.join(System.tmp_dir!(), "pd_verify_#{System.unique_integer([:positive])}")

    try do
      {:ok, path} = ReplayArtifact.write(term, dir)

      Campaign.run(
        model: model,
        targets: [Target.to_entry(target)],
        only: [replay: path],
        replay_dir: false,
        verbose: false
      )
    after
      File.rm_rf!(dir)
    end
  end
end
