defmodule PropertyDamage.ExportDivergenceNameTest do
  # A divergence is named by its observation, a `{projection, function}`
  # pair. Every exporter names it as `Projection.function`, as the report does.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Export, Failure, FailureReport, Sequence}

  defmodule Deposit do
    @moduledoc false
    defstruct [:amount]
  end

  defmodule Totals do
    @moduledoc false
  end

  defmodule Adapter do
    @moduledoc false
  end

  @name "PropertyDamage.ExportDivergenceNameTest.Totals.balance"

  defp divergence_report do
    sequence = Sequence.linear([%Deposit{amount: 1}, %Deposit{amount: 2}])

    FailureReport.new(
      seed: 42,
      run_number: 0,
      original_sequence: sequence,
      shrunk_sequence: sequence,
      failed_at_index: 1,
      failure_reason:
        Failure.diverged(%{
          key: {Totals, :balance},
          root: 1,
          command: %Deposit{amount: 2},
          reference_value: 3,
          variant_value: 4,
          mismatch: "3 != 4"
        }),
      targets: [{Adapter, name: "left"}, {Adapter, name: "right"}],
      variant: %{index: 1, name: "right"}
    )
  end

  for language <- [:curl, :python, :elixir] do
    @language language
    test "the #{language} script names the observation" do
      script = Export.to_script(divergence_report(), @language, base_url: "http://localhost")
      assert script =~ @name
    end
  end

  test "the ExUnit test names the observation" do
    code = Export.to_exunit(divergence_report())
    assert code =~ @name
    assert {:ok, _quoted} = Code.string_to_quoted(code)
  end

  test "the Livebook notebook names the observation" do
    notebook = Export.to_livebook(divergence_report(), base_url: "http://localhost")
    assert notebook =~ @name
  end
end
