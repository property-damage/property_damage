defmodule PropertyDamage.SetupVariantTextTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Error, ErrorOrigin, Failure}
  alias PropertyDamage.Failure.Explain

  defp variant_failure, do: Failure.setup_failed(:variant, detail: {:exit, :killed})

  test "Error.format names the variant crash and its exit reason" do
    text = Error.format(variant_failure(), %{})

    assert text =~ "variant process died"
    assert text =~ ":killed"
    refute text =~ "setup/1"
    refute text =~ "setup commands"
  end

  test "ErrorOrigin does not blame the adapter's setup/1 for a variant crash" do
    %{origin: origin, details: details} = ErrorOrigin.classify(variant_failure())

    assert origin == :unknown
    assert details.reason =~ "variant process"
    refute details.reason =~ "setup/1"
    assert details.evidence.reason =~ ":killed"
  end

  test "the setup_failed meaning covers the model and variant causes" do
    meaning = Explain.meaning(:setup_failed)

    assert meaning =~ "model code"
    assert meaning =~ "variant process"
  end
end
