defmodule SequenceValidityTest do
  @moduledoc """
  The model's projection rejects a command that references an owner, repo or
  issue no earlier command created. The shrinker treats a candidate whose
  validation raises as invalid, so shrinking cannot keep an orphaned command
  after dropping the command it depends on. Needs no running forge.
  """

  use ExUnit.Case, async: true

  alias GiteaBench.Commands.{CreateIssue, CreateLabel, CreateRepo, CreateUser}
  alias PropertyDamage.Sequence.Validator

  # The shrinker's rule: a candidate whose validation raises is invalid.
  defp valid?(commands) do
    Validator.valid_sequence?(commands, GiteaBench.Model)
  rescue
    _ -> false
  end

  test "a repo whose owner no earlier command created is not a valid sequence" do
    commands = [
      %CreateUser{login: "u1", email: "u1@pd.local"},
      %CreateRepo{owner: "u0", name: "r6"}
    ]

    refute valid?(commands)

    assert_raise ArgumentError, ~r/"u0"/, fn ->
      Validator.valid_sequence?(commands, GiteaBench.Model)
    end
  end

  test "an issue or label on a repo no earlier command created is not a valid sequence" do
    user = %CreateUser{login: "u0", email: "u0@pd.local"}

    refute valid?([user, %CreateIssue{repo: "u0/r6", title: "bug"}])
    refute valid?([user, %CreateLabel{repo: "u0/r6", name: "l0", color: "ff0000"}])
  end

  test "control: the same commands after the commands they reference are valid" do
    assert valid?([
             %CreateUser{login: "u0", email: "u0@pd.local"},
             %CreateRepo{owner: "u0", name: "r6"},
             %CreateIssue{repo: "u0/r6", title: "bug"},
             %CreateLabel{repo: "u0/r6", name: "l0", color: "ff0000"}
           ])
  end
end
