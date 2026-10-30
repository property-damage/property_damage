defmodule PropertyDamage.FailureReport.BundleRedactionMoreTest do
  # The redaction also reads a quoted map key as the name of a secret, and
  # follows a secret onto the next line when the formatter wrapped the call.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport.Bundle.Redaction

  defp line_count(text), do: length(String.split(text, "\n"))

  describe "a quoted map key names a secret" do
    for {name, text, key} <- [
          {"a string key with =>", ~S(%{"password" => "hunter2"}), ~S("password" =>)},
          {"a keyword-style string key", ~S(%{"admin_password": "hunter2"}),
           ~S("admin_password":)}
        ] do
      test "replaces the value after #{name} and keeps the key" do
        {redacted, count} = Redaction.redact(unquote(text))

        refute redacted =~ "hunter2"
        assert redacted =~ ~S("[REDACTED]")
        assert redacted =~ unquote(key)
        assert count == 1
      end
    end

    test "replaces the literal on the line that wraps after a secret name" do
      text = ~s|Map.get(config, :admin_password,\n  "Admin-12345")|
      {redacted, count} = Redaction.redact(text)

      refute redacted =~ "Admin-12345"
      assert redacted =~ ":admin_password,"
      assert redacted =~ ~S("[REDACTED]")
      assert count == 1
      assert line_count(redacted) == line_count(text)
    end
  end

  describe "text that names no secret" do
    for {name, text} <- [
          {"a key that ends in a plural", ~S(%{"keys" => "x"})},
          {"a key that merely ends in key", ~S(%{"monkey": "x"})},
          {"a secret line that does not end in a comma or bracket",
           ~s|Map.get(config, :admin_password)\n"next"|},
          {"a wrapped call without a secret word", ~s|foo(:amount,\n "x")|}
        ] do
      test "leaves #{name} untouched" do
        text = unquote(text)
        assert Redaction.redact(text) == {text, 0}
      end
    end
  end

  test "keeps the line count in every case" do
    text = ~s|%{"password" => "a"}\nMap.get(c, :token,\n  "b")\nx = 1|
    {redacted, _count} = Redaction.redact(text)

    assert line_count(redacted) == line_count(text)
  end

  test "reads a bare string that is not a key as no secret name" do
    text = ~S|Map.get(config, "token")|
    assert Redaction.redact(text) == {text, 0}
  end

  test "stops after one wrapped line" do
    text = ~s|Map.get(c, :token,\n  "a",\n  "b")|
    {redacted, count} = Redaction.redact(text)

    assert redacted =~ ~S("b")
    assert count == 1
  end
end
