defmodule PropertyDamage.FailureReport.Bundle do
  @moduledoc """
  The failure document under its page name: `build/2` is
  `PropertyDamage.FailureReport.Document.build/2`.

  The document holds the source members only with `sources: true`; the
  `PropertyDamage.FailureReport.Document` moduledoc lists every key.
  """

  alias PropertyDamage.FailureReport
  alias PropertyDamage.FailureReport.Document

  @doc """
  Returns the document of `report`, with `opts` passed through to
  `PropertyDamage.FailureReport.Document.build/2`.
  """
  @spec build(FailureReport.t(), keyword()) :: map()
  def build(%FailureReport{} = report, opts \\ []), do: Document.build(report, opts)
end
