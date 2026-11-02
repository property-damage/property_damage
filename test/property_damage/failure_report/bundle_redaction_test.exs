defmodule PropertyDamage.FailureReport.BundleRedactionTest do
  # The source of an adapter can hold a secret: a password or a token that the
  # adapter uses to reach the system under test. The bundle replaces every
  # double-quoted literal on a line that names a secret, and counts the
  # replacements. The rule is a line rule, so a harmless literal on such a
  # line is replaced too, and a secret in a heredoc is not found.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport.HTML
  alias PropertyDamage.Test.BundleSupport, as: B

  setup do
    previous = System.get_env("PD_LOG")
    System.delete_env("PD_LOG")

    on_exit(fn ->
      if previous, do: System.put_env("PD_LOG", previous), else: System.delete_env("PD_LOG")
    end)

    :ok
  end

  # Redacts `input` and checks the positive control: the literal is in the
  # input, and it is gone from the output.
  defp redacted(input, literal) do
    assert String.contains?(input, literal), "the input must hold #{inspect(literal)}"
    {output, count} = B.redact(input)
    refute String.contains?(output, literal), "the output still holds #{inspect(literal)}"
    {output, count}
  end

  describe "redact/1, on a line that names a secret" do
    test "replaces the literal of a module attribute named secret" do
      assert {~S(@report_secret "[REDACTED]"), 1} =
               redacted(~S(@report_secret "pd-sandbox"), "pd-sandbox")
    end

    test "replaces the literal of a keyword named password" do
      assert {~S(password: "[REDACTED]"), 1} = redacted(~S(password: "hunter2"), "hunter2")
    end

    test "replaces the default of a lookup whose key is an atom named admin_password" do
      input = ~S|Map.get(config, :admin_password, "Alice-12345")|

      assert {~S|Map.get(config, :admin_password, "[REDACTED]")|, 1} =
               redacted(input, "Alice-12345")
    end

    test "replaces the literal of a variable named api_key" do
      assert {~S(api_key = "[REDACTED]"), 1} = redacted(~S(api_key = "hunter2"), "hunter2")
    end

    test "replaces the literal a function named api_token returns" do
      assert {~S|def api_token, do: "[REDACTED]"|, 1} =
               redacted(~S|def api_token, do: "hunter2"|, "hunter2")
    end

    test "replaces the literal of a client_secret keyword" do
      assert {~S(client_secret: "[REDACTED]"), 1} =
               redacted(~S(client_secret: "bob-secret"), "bob-secret")
    end

    test "replaces a harmless literal on that line too, as the rule is by line" do
      assert {~S(key: "[REDACTED]"), 1} = redacted(~S(key: "amount"), "amount")
    end

    test "replaces every literal of the line, and counts each" do
      assert {~S|put_secret("[REDACTED]", "[REDACTED]")|, 2} =
               redacted(~S|put_secret("alice", "hunter2")|, "hunter2")
    end

    test "counts a replaced literal on each line of a text and keeps the other lines" do
      input = """
      defmodule MyApp.Adapter do
        @api_token "hunter2"
        @base_url "http://localhost"

        def login, do: post(password: "hunter3")
      end
      """

      {output, count} = redacted(input, "hunter2")

      assert count == 2
      refute output =~ "hunter3"
      assert output =~ ~S(@api_token "[REDACTED]")
      assert output =~ ~S(@base_url "http://localhost")
      assert output =~ ~S|post(password: "[REDACTED]")|
      assert String.split(output, "\n") |> length() == String.split(input, "\n") |> length()
    end

    test "reads an escaped quote inside a literal as part of the literal" do
      input = ~S(@api_token "a\"b")

      assert {~S(@api_token "[REDACTED]"), 1} = redacted(input, ~S(a\"b))
    end

    test "gives the same text when it redacts the output again" do
      {once, _count} = B.redact(~S(@api_token "hunter2"))
      {twice, _count} = B.redact(once)

      assert twice == once
    end
  end

  describe "redact/1, on a line that names no secret" do
    test "leaves a line that names keys alone" do
      input = ~S|keys = Map.keys(m)|

      assert {^input, 0} = B.redact(input)
    end

    test "leaves a literal on a line that names keys alone" do
      input = ~S|keys = ["alice", "bob"]|

      assert {^input, 0} = B.redact(input)
    end

    test "leaves keyword and monkey alone" do
      for input <- [
            ~S|keyword: "alice"|,
            ~S|monkey = "bob"|,
            ~S|Keyword.get(opts, :name, "alice")|
          ] do
        assert {^input, 0} = B.redact(input)
      end
    end

    test "leaves a bare literal that only spells a secret word alone" do
      for input <- [
            ~S|String.contains?(text, "token")|,
            ~S|IO.puts("the password is not here")|,
            ~S|assert kind == "secret"|
          ] do
        assert {^input, 0} = B.redact(input)
      end
    end

    test "leaves a text with no secret unchanged, with a count of zero" do
      input = """
      defmodule MyApp.Adapter do
        def execute(_command, ctx, _runtime), do: {:ok, [%MyApp.Paid{by: "alice"}]}
      end
      """

      assert {^input, 0} = B.redact(input)
    end
  end

  describe "redact/1, on text it does not touch" do
    test "leaves a heredoc alone" do
      input = ~s(@api_token """\nhunter2\n"""\n)

      assert {^input, 0} = B.redact(input)
    end

    test "leaves a sigil alone" do
      for input <- [~S|@api_key ~s(hunter2)|, ~S|@api_key ~S"hunter2"|] do
        assert {^input, 0} = B.redact(input)
      end
    end

    test "leaves a charlist alone" do
      input = ~S|@api_key 'hunter2'|

      assert {^input, 0} = B.redact(input)
    end
  end

  describe "the bundle, for the source of an adapter" do
    @adapter_extra ~S'''
    @api_token "hunter2"
    def api_token, do: @api_token
    '''

    test "holds the source without the literal, with the replacement" do
      system = B.define(adapter_extra: @adapter_extra)
      assert File.read!(system.adapter_file) =~ "hunter2"

      entry = system |> B.run() |> B.build() |> B.module_entry(system.adapter)

      refute entry["source"] =~ "hunter2"
      assert entry["source"] =~ ~S(@api_token "[REDACTED]")
      assert entry["redactions"] >= 1
    end

    test "keeps the line count and the ranges of the file" do
      system = B.define(adapter_extra: @adapter_extra)
      entry = system |> B.run() |> B.build() |> B.module_entry(system.adapter)

      assert entry["lines"] == B.line_count(system.adapter_file)

      assert length(String.split(String.trim_trailing(entry["source"], "\n"), "\n")) ==
               entry["lines"]

      execute = B.function_entry(entry, :execute, 3)
      assert execute["from"] == B.line_of(system.adapter_source, ~r/^  def execute/)
    end

    test "counts the replacements at the top level, with the rule in a sentence" do
      system = B.define(adapter_extra: @adapter_extra)
      bundle = system |> B.run() |> B.build()

      assert %{"count" => count, "rule" => rule} = bundle["redactions"]
      assert count >= 1
      assert is_binary(rule) and String.length(rule) > 20

      per_module = bundle["modules"] |> Enum.map(& &1["redactions"]) |> Enum.sum()
      assert count == per_module
    end

    test "leaves the page without the literal in its bundle" do
      system = B.define(adapter_extra: @adapter_extra)
      html = system |> B.run() |> HTML.render()

      assert [content] = B.bundle_tags(html)
      refute content =~ "hunter2"
      assert content =~ "[REDACTED]"
    end

    test "counts nothing for an adapter without a secret, and keeps its source" do
      system = B.define()
      bundle = system |> B.run() |> B.build()
      entry = B.module_entry(bundle, system.adapter)

      assert entry["redactions"] == 0
      assert entry["source"] == system.adapter_source
      assert bundle["redactions"]["count"] == 0
    end
  end

  describe "the bundle, for a module that is not an adapter" do
    @model_extra ~S'''
    @api_token "hunter2"
    def api_token, do: @api_token
    '''

    test "keeps the literal in the source of a model" do
      system = B.define(model_extra: @model_extra)

      bundle = system |> B.run() |> B.build()
      entry = B.module_entry(bundle, system.model)

      assert entry["source"] =~ ~S(@api_token "hunter2")
      assert entry["redactions"] == 0
      assert bundle["redactions"]["count"] == 0
    end
  end
end
