defmodule PropertyDamage.BranchingOptionConflictsTest do
  # `branching:` runs on one target through the linear engine, one branch at
  # a time. Two options that path cannot honor are refused at validation
  # instead of being accepted and ignored.
  use ExUnit.Case, async: true

  alias PropertyDamage.Options

  defp base,
    do: [model: PropertyDamage.Test.MinimalModel, targets: [PropertyDamage.Test.TestAdapter]]

  defp validate(extra), do: Options.validate_run!(base() ++ extra)

  test "latency: with branching: is an option error" do
    error =
      assert_raise NimbleOptions.ValidationError, fn ->
        validate(branching: [], latency: true)
      end

    assert error.message =~ "`latency:`"
    assert error.message =~ "`branching:`"
    assert error.message =~ "no latency samples"
  end

  test "a check_mode: other than the default with branching: is an option error" do
    for mode <- [:record, :log, :disabled] do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          validate(branching: [], check_mode: mode)
        end

      assert error.message =~ "`check_mode: #{inspect(mode)}`"
      assert error.message =~ "`branching:`"
    end
  end

  test "the default check_mode: beside branching: is accepted, spelled out or not" do
    assert validate(branching: [])[:check_mode] == :halt
    assert validate(branching: [], check_mode: :halt)[:check_mode] == :halt
  end

  test "latency: and a check_mode: without branching: are accepted as before" do
    assert validate(latency: true)[:latency] == [warmup: 0]
    assert validate(check_mode: :record)[:check_mode] == :record
  end
end
