defmodule PropertyDamage.FailureReport.ExplanationPinTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.ExplainSupport, as: E

  # The instructions are written for one prompt version. Changing their text
  # without a new version would let an explanation written for the old text
  # count as current.
  @pinned_version 1
  @pinned_sha256 "c5b9b8a6ab9c6207d89878ca79a32ba6226e3af79f55829cf1b4aa497c979131"

  test "the prompt version and the instructions change together" do
    assert {E.prompt_version(), E.sha256(E.instructions())} ==
             {@pinned_version, @pinned_sha256},
           "the instructions changed: bump @prompt_version in " <>
             "PropertyDamage.FailureReport.Explanation and update this pin"
  end

  test "the instructions are the bytes of the shipped file" do
    path = Path.join(:code.priv_dir(:property_damage), "explain/instructions.md")

    assert File.exists?(path), "the instructions file #{path} does not exist"
    assert E.instructions() == File.read!(path)
  end
end
