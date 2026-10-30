defmodule Mix.Tasks.Pd.ExplainApplyTest do
  # async: false because the task prints to stdout and stderr, which the tests
  # capture, and capturing stderr is global.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.ExplainSupport, as: E

  @page_hash "2a79640f06d21f6c1c8da9df035e4f3f6f326bdf7d65440b13dcb2dfa7357656"
  @other_hash "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  @old_explanation ~s({"format":1,"bundle_hash":"#{@other_hash}","prompt_version":1,"explanation":{"old":true}})

  defp valid, do: E.explanation_fixture("valid.json")

  defp hyp(map, index, fun), do: update_in(map, ["hypotheses", Access.at(index)], fun)
  defp entry(map, key, index, fun), do: update_in(map, [key, Access.at(index)], fun)

  defp applied_line(page),
    do: "applied the explanation to #{page} (bundle #{@page_hash}, prompt version 1)\n"

  # Runs `--apply` on a fresh copy of the fixture page and asserts the run
  # rejects it with exactly `expected` on stderr (`:ordered` compares the
  # lines in order, `:set` compares them as a set), nothing on stdout, the
  # page byte for byte as before and no new file in its directory.
  defp assert_rejected(dir, spec, expected, order \\ :set) do
    page = E.copy(dir, "page.html")
    file = E.explanation_file(dir, spec)
    bytes = File.read!(page)
    before = E.tree(dir)

    out = E.exec([page, "--apply", file])

    assert out.result == :error
    assert out.stdout == ""
    assert_lines(out.stderr, expected, order)
    assert File.read!(page) == bytes
    assert E.tree(dir) == before
  end

  # Schema lines come first and in any order; the lines after them keep their
  # order.
  defp assert_lines(stderr, expected, :ordered) do
    schema? = &String.starts_with?(&1, "schema: ")
    {schema, rest} = stderr |> E.lines() |> Enum.split_while(schema?)
    {expected_schema, expected_rest} = Enum.split_while(expected, schema?)

    assert Enum.sort(schema) == Enum.sort(expected_schema)
    assert rest == expected_rest
  end

  defp assert_lines(stderr, expected, :set) do
    assert Enum.sort(E.lines(stderr)) == Enum.sort(expected)
  end

  # Runs `--apply` and asserts the run succeeds; returns the page's old and
  # new bytes and the output.
  defp assert_applied(dir, spec, opts \\ []) do
    page = Keyword.get_lazy(opts, :page, fn -> E.copy(dir, "page.html") end)
    file = E.explanation_file(dir, spec)
    bytes = File.read!(page)
    before = E.tree(dir)

    out = E.exec([page, "--apply", file])

    assert out.result == :ok, "the explanation was rejected: #{out.stderr}"
    assert out.stderr == ""
    assert out.stdout == applied_line(page)
    assert E.tree(dir) == before
    %{page: page, old: bytes, new: File.read!(page), out: out}
  end

  describe "an explanation that fails a check" do
    @tag :tmp_dir
    test "unknown ids are listed in order, each once", %{tmp_dir: dir} do
      assert_rejected(
        dir,
        "bad_ids.json",
        [
          "failure:Nope: not in this page",
          "step:alice:[0] : not in this page",
          "section:Nowhere: not in this page"
        ],
        :ordered
      )
    end

    @tag :tmp_dir
    test "a line range outside the source names the module's line count", %{tmp_dir: dir} do
      ledger = E.mod("Ledger")
      model = E.mod("Model")

      assert_rejected(
        dir,
        "out_of_range_source.json",
        [
          "source:#{ledger}:60-70: lines 60-70 outside 1-64",
          "source:#{model}:0-5: lines 0-5 outside 1-64"
        ],
        :ordered
      )
    end

    @tag :tmp_dir
    test "a hypothesis without a rank is a schema error", %{tmp_dir: dir} do
      assert_rejected(dir, "missing_rank.json", ["schema: hypotheses[0].rank: missing"])
    end

    @tag :tmp_dir
    test "a hypothesis without a likelihood is a schema error", %{tmp_dir: dir} do
      assert_rejected(dir, "missing_likelihood.json", [
        "schema: hypotheses[1].likelihood: missing"
      ])
    end

    @tag :tmp_dir
    test "a hypothesis more likely than the one ranked above it is a schema error", %{
      tmp_dir: dir
    } do
      assert_rejected(dir, "likelihood_order.json", [
        "schema: hypotheses[1].likelihood: likely is higher than possible in hypotheses[0]"
      ])
    end

    @tag :tmp_dir
    test "a gap line cited as evidence is reported once", %{tmp_dir: dir} do
      assert_rejected(
        dir,
        "gap_as_evidence.json",
        ["context:Model: a missing description is not evidence"],
        :ordered
      )
    end

    @tag :tmp_dir
    test "every schema violation is listed", %{tmp_dir: dir} do
      assert_rejected(dir, "schema_violation.json", [
        "schema: unknown key extra",
        "schema: summary[0]: unknown key note",
        "schema: summary[0].text: must be a non-empty string",
        "schema: hypotheses[0].rank: must be an integer",
        "schema: hypotheses[0].likelihood: must be likely, possible or unlikely",
        "schema: hypotheses[0].evidence: must be a non-empty list of strings",
        "schema: hypotheses[0].next_steps: must be a non-empty list of non-empty strings",
        "schema: hypotheses[1]: unknown key mood",
        "schema: hypotheses[1].claim: must be a non-empty string",
        "schema: talking_points[0].cites: must be a non-empty list of strings"
      ])
    end

    @tag :tmp_dir
    test "a bundle hash that is not the page's is reported with both hashes", %{tmp_dir: dir} do
      assert_rejected(dir, "hash_mismatch.json", [
        "bundle hash mismatch: explanation #{String.duplicate("0123456789abcdef", 4)}, page #{@page_hash}"
      ])
    end

    @tag :tmp_dir
    test "schema lines come first, then the hash line, then the citation lines", %{tmp_dir: dir} do
      spec =
        valid()
        |> hyp(0, &Map.delete(&1, "rank"))
        |> Map.put("bundle_hash", @other_hash)
        |> entry("summary", 0, &Map.put(&1, "cites", ["failure:Nope"]))
        |> entry("talking_points", 0, &Map.put(&1, "cites", ["failure:Zip"]))

      assert_rejected(
        dir,
        spec,
        [
          "schema: hypotheses[0].rank: missing",
          "bundle hash mismatch: explanation #{@other_hash}, page #{@page_hash}",
          "failure:Nope: not in this page",
          "failure:Zip: not in this page"
        ],
        :ordered
      )
    end

    @tag :tmp_dir
    test "a page that already holds an explanation stays as it is", %{tmp_dir: dir} do
      html = E.with_tag_after_bundle(E.fixture("page.html"), @old_explanation)
      page = E.write(dir, "explained.html", html)
      file = E.explanation_file(dir, "bad_ids.json")
      before = E.tree(dir)

      out = E.exec([page, "--apply", file])

      assert out.result == :error
      assert out.stdout == ""
      assert File.read!(page) == html
      assert E.tree(dir) == before
    end
  end

  describe "the input is not an explanation object" do
    @tag :tmp_dir
    test "undecodable text, an array and other values give one schema line", %{tmp_dir: dir} do
      for raw <- ["", "{bad", "[1]", ~s("text"), "null", "7", ~s({"summary":)] do
        page = E.copy(dir, "page.html")
        file = E.explanation_file(dir, {:raw, raw})
        bytes = File.read!(page)
        before = E.tree(dir)

        out = E.exec([page, "--apply", file])

        assert out.result == :error, inspect(raw)
        assert out.stdout == "", inspect(raw)
        assert [line] = E.lines(out.stderr), inspect(raw)
        assert String.starts_with?(line, "schema: not a JSON object (")
        assert String.ends_with?(line, ")")
        assert File.read!(page) == bytes
        assert E.tree(dir) == before
      end
    end
  end

  describe "the schema" do
    @tag :tmp_dir
    test "names each missing or wrongly shaped part with a zero-based path", %{tmp_dir: dir} do
      list_of_objects = "must be a non-empty list of objects"
      string_list = "must be a non-empty list of strings"
      non_empty = "must be a non-empty string"

      cases = [
        {Map.delete(valid(), "summary"), ["schema: summary: missing"]},
        {Map.delete(valid(), "hypotheses"), ["schema: hypotheses: missing"]},
        {Map.delete(valid(), "talking_points"), ["schema: talking_points: missing"]},
        {Map.put(valid(), "summary", []), ["schema: summary: #{list_of_objects}"]},
        {Map.put(valid(), "summary", "text"), ["schema: summary: #{list_of_objects}"]},
        {Map.put(valid(), "hypotheses", []), ["schema: hypotheses: #{list_of_objects}"]},
        {Map.put(valid(), "talking_points", %{}), ["schema: talking_points: #{list_of_objects}"]},
        {entry(valid(), "summary", 1, fn _ -> 1 end), ["schema: summary[1]: must be an object"]},
        {hyp(valid(), 2, fn _ -> [] end), ["schema: hypotheses[2]: must be an object"]},
        {entry(valid(), "summary", 0, &Map.delete(&1, "text")),
         ["schema: summary[0].text: missing"]},
        {entry(valid(), "summary", 0, &Map.delete(&1, "cites")),
         ["schema: summary[0].cites: missing"]},
        {entry(valid(), "summary", 0, &Map.put(&1, "text", "")),
         ["schema: summary[0].text: #{non_empty}"]},
        {entry(valid(), "summary", 0, &Map.put(&1, "cites", [])),
         ["schema: summary[0].cites: #{string_list}"]},
        {entry(valid(), "summary", 0, &Map.put(&1, "cites", "failure:Message")),
         ["schema: summary[0].cites: #{string_list}"]},
        {entry(valid(), "talking_points", 1, &Map.put(&1, "cites", ["failure:Check", 3])),
         ["schema: talking_points[1].cites: #{string_list}"]},
        {entry(valid(), "talking_points", 1, &Map.put(&1, "why", "x")),
         ["schema: talking_points[1]: unknown key why"]},
        {hyp(valid(), 0, &Map.delete(&1, "claim")), ["schema: hypotheses[0].claim: missing"]},
        {hyp(valid(), 0, &Map.delete(&1, "evidence")),
         ["schema: hypotheses[0].evidence: missing"]},
        {hyp(valid(), 0, &Map.delete(&1, "next_steps")),
         ["schema: hypotheses[0].next_steps: missing"]},
        {hyp(valid(), 1, &Map.put(&1, "next_steps", ["check it", ""])),
         ["schema: hypotheses[1].next_steps: must be a non-empty list of non-empty strings"]},
        {hyp(valid(), 1, &Map.put(&1, "rank", "2")),
         ["schema: hypotheses[1].rank: must be an integer"]},
        {hyp(valid(), 1, &Map.put(&1, "likelihood", 5)),
         ["schema: hypotheses[1].likelihood: must be likely, possible or unlikely"]},
        {Map.put(valid(), "bundle_hash", 5), ["schema: bundle_hash: must be a string"]},
        {Map.put(valid(), "hint", []), ["schema: unknown key hint"]}
      ]

      for {spec, expected} <- cases, do: assert_rejected(dir, spec, expected)
    end

    @tag :tmp_dir
    test "ranks must run from 1 in order, each once", %{tmp_dir: dir} do
      line = "schema: hypotheses: ranks must run 1 to 3 in order, each once"

      for ranks <- [[1, 2, 2], [2, 1, 3], [1, 2, 4], [0, 1, 2], [1, 1, 1]] do
        spec =
          Enum.reduce(Enum.with_index(ranks), valid(), fn {rank, i}, acc ->
            hyp(acc, i, &Map.put(&1, "rank", rank))
          end)

        assert_rejected(dir, spec, [line])
      end

      one = Map.update!(valid(), "hypotheses", &[Map.put(hd(&1), "rank", 2)])
      assert_rejected(dir, one, ["schema: hypotheses: ranks must run 1 to 1 in order, each once"])
    end

    @tag :tmp_dir
    test "the rank check waits until every rank is an integer", %{tmp_dir: dir} do
      spec = hyp(valid(), 0, &Map.put(&1, "rank", 2.0))
      assert_rejected(dir, spec, ["schema: hypotheses[0].rank: must be an integer"])
    end

    @tag :tmp_dir
    test "likelihood order is checked for each adjacent pair of valid likelihoods", %{
      tmp_dir: dir
    } do
      cases = [
        {["likely", "unlikely", "possible"],
         ["schema: hypotheses[2].likelihood: possible is higher than unlikely in hypotheses[1]"]},
        {["unlikely", "unlikely", "likely"],
         ["schema: hypotheses[2].likelihood: likely is higher than unlikely in hypotheses[1]"]},
        {["unlikely", "possible", "likely"],
         [
           "schema: hypotheses[1].likelihood: possible is higher than unlikely in hypotheses[0]",
           "schema: hypotheses[2].likelihood: likely is higher than possible in hypotheses[1]"
         ]},
        {["likely", "bogus", "possible"],
         ["schema: hypotheses[1].likelihood: must be likely, possible or unlikely"]}
      ]

      for {words, expected} <- cases do
        spec =
          Enum.reduce(Enum.with_index(words), valid(), fn {word, i}, acc ->
            hyp(acc, i, &Map.put(&1, "likelihood", word))
          end)

        assert_rejected(dir, spec, expected)
      end
    end

    @tag :tmp_dir
    test "equal likelihoods and a non-increasing order are accepted", %{tmp_dir: dir} do
      for words <- [["likely", "likely", "likely"], ["likely", "possible", "possible"]] do
        spec =
          Enum.reduce(Enum.with_index(words), valid(), fn {word, i}, acc ->
            hyp(acc, i, &Map.put(&1, "likelihood", word))
          end)

        assert_applied(dir, spec)
      end
    end
  end

  describe "the citations" do
    @tag :tmp_dir
    test "ranges at the edges of a module's source resolve", %{tmp_dir: dir} do
      ledger = E.mod("Ledger")
      adapter = E.mod("Adapter")

      spec =
        entry(valid(), "summary", 0, fn e ->
          Map.put(e, "cites", [
            "source:#{ledger}:1-64",
            "source:#{ledger}:64-64",
            "source:#{ledger}:1-1",
            "source:#{adapter}:1-21"
          ])
        end)

      assert_applied(dir, spec)
    end

    @tag :tmp_dir
    test "every id form that does not resolve is reported as the contract words it", %{
      tmp_dir: dir
    } do
      ledger = E.mod("Ledger")
      adapter = E.mod("Adapter")
      fun = "source:#{ledger}.assert_not_negative/2"

      cites = [
        "source:#{ledger}:1-65",
        "source:#{ledger}:5-3",
        "source:#{adapter}:1-22",
        "source:#{E.mod("Paid")}:1-2",
        "source:#{E.mod("Led")}:1-2",
        "source:#{ledger}x:1-2",
        "source:#{ledger}:a-b",
        "source:#{ledger}:1",
        "source:#{ledger}",
        "source:#{E.mod("Nope")}:1-2",
        fun <> " ",
        " " <> fun,
        "source:#{ledger}.init/1",
        "FAILURE:MESSAGE",
        "failure:Message",
        fun
      ]

      spec = entry(valid(), "summary", 0, &Map.put(&1, "cites", cites))

      assert_rejected(
        dir,
        spec,
        [
          "source:#{ledger}:1-65: lines 1-65 outside 1-64",
          "source:#{ledger}:5-3: lines 5-3 outside 1-64",
          "source:#{adapter}:1-22: lines 1-22 outside 1-21",
          "source:#{E.mod("Paid")}:1-2: not in this page",
          "source:#{E.mod("Led")}:1-2: not in this page",
          "source:#{ledger}x:1-2: not in this page",
          "source:#{ledger}:a-b: not in this page",
          "source:#{ledger}:1: not in this page",
          "source:#{ledger}: not in this page",
          "source:#{E.mod("Nope")}:1-2: not in this page",
          fun <> " : not in this page",
          " " <> fun <> ": not in this page",
          "source:#{ledger}.init/1: not in this page",
          "FAILURE:MESSAGE: not in this page"
        ],
        :ordered
      )
    end

    @tag :tmp_dir
    test "ids are reported in order of first appearance across the three parts", %{tmp_dir: dir} do
      spec =
        valid()
        |> entry("talking_points", 0, &Map.put(&1, "cites", ["failure:Aaa", "failure:Ccc"]))
        |> hyp(1, &Map.put(&1, "evidence", ["failure:Ddd", "failure:Bbb"]))
        |> hyp(0, &Map.put(&1, "evidence", ["failure:Bbb"]))
        |> entry("summary", 1, &Map.put(&1, "cites", ["failure:Eee", "failure:Ccc"]))
        |> entry("summary", 0, &Map.put(&1, "cites", ["failure:Ccc", "failure:Aaa"]))

      assert_rejected(
        dir,
        spec,
        for(id <- ~w(Ccc Aaa Eee Bbb Ddd), do: "failure:#{id}: not in this page"),
        :ordered
      )
    end

    @tag :tmp_dir
    test "a gap line may be cited in the summary and the talking points", %{tmp_dir: dir} do
      spec = entry(valid(), "talking_points", 0, &Map.put(&1, "cites", ["context:Model"]))

      assert_applied(dir, spec)
    end

    @tag :tmp_dir
    test "a gap line in evidence is reported next to other bad ids", %{tmp_dir: dir} do
      spec = hyp(valid(), 0, &Map.put(&1, "evidence", ["context:Model", "failure:Nope"]))

      assert_rejected(
        dir,
        spec,
        [
          "context:Model: a missing description is not evidence",
          "failure:Nope: not in this page"
        ],
        :ordered
      )
    end

    @tag :tmp_dir
    test "a part with a wrong shape is skipped and the other parts are still checked", %{
      tmp_dir: dir
    } do
      spec =
        valid()
        |> entry("summary", 0, &Map.put(&1, "cites", "failure:Nope"))
        |> hyp(0, &Map.put(&1, "evidence", [1]))
        |> hyp(1, &Map.put(&1, "evidence", ["failure:Bad"]))
        |> entry("talking_points", 1, &Map.put(&1, "cites", ["failure:Zap"]))

      assert_rejected(
        dir,
        spec,
        [
          "schema: summary[0].cites: must be a non-empty list of strings",
          "schema: hypotheses[0].evidence: must be a non-empty list of strings",
          "failure:Bad: not in this page",
          "failure:Zap: not in this page"
        ],
        :ordered
      )
    end

    @tag :tmp_dir
    test "a hypotheses value that is not a list skips every hypothesis citation", %{tmp_dir: dir} do
      spec =
        valid()
        |> Map.put("hypotheses", "none")
        |> entry("summary", 0, &Map.put(&1, "cites", ["failure:Nope"]))

      assert_rejected(
        dir,
        spec,
        [
          "schema: hypotheses: must be a non-empty list of objects",
          "failure:Nope: not in this page"
        ],
        :ordered
      )
    end
  end

  describe "stdin" do
    @tag :tmp_dir
    test "--apply - reads a valid explanation from stdin", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      original = File.read!(page)
      before = E.tree(dir)

      out = E.exec([page, "--apply", "-"], input: E.fixture("valid.json"))

      assert out.result == :ok
      assert out.stderr == ""
      assert out.stdout == applied_line(page)
      assert E.tree(dir) == before
      assert [json] = E.explanation_tags(File.read!(page))
      assert Jason.decode!(json)["explanation"] == valid()
      assert File.read!(page) == E.expected_page(original, json)
    end

    @tag :tmp_dir
    test "--apply - rejects an invalid explanation from stdin", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      bytes = File.read!(page)
      before = E.tree(dir)

      out = E.exec([page, "--apply", "-"], input: E.fixture("bad_ids.json"))

      assert out.result == :error
      assert out.stdout == ""

      assert E.lines(out.stderr) == [
               "failure:Nope: not in this page",
               "step:alice:[0] : not in this page",
               "section:Nowhere: not in this page"
             ]

      assert File.read!(page) == bytes
      assert E.tree(dir) == before
    end

    @tag :tmp_dir
    test "--apply - on text that is not JSON gives the schema line", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      bytes = File.read!(page)

      out = E.exec([page, "--apply", "-"], input: "not json")

      assert out.result == :error
      assert [line] = E.lines(out.stderr)
      assert String.starts_with?(line, "schema: not a JSON object (")
      assert File.read!(page) == bytes
    end
  end

  describe "a valid explanation" do
    @tag :tmp_dir
    test "is embedded right after the bundle, byte for byte", %{tmp_dir: dir} do
      run = assert_applied(dir, "valid.json")

      assert E.tag_count(run.new, "pd-bundle") == 1
      assert E.tag_count(run.new, "pd-explanation") == 1
      assert [json] = E.explanation_tags(run.new)

      assert Jason.decode!(json) == %{
               "format" => 1,
               "bundle_hash" => @page_hash,
               "prompt_version" => 1,
               "explanation" => valid()
             }

      assert run.new == E.expected_page(run.old, json)
      assert E.bundle_bytes(run.new) == E.bundle_bytes(run.old)
      assert E.bundle_hash(run.new) == @page_hash
      refute String.contains?(json, "</")
    end

    @tag :tmp_dir
    test "may carry the page's bundle hash, which is not copied into the explanation", %{
      tmp_dir: dir
    } do
      run = assert_applied(dir, Map.put(valid(), "bundle_hash", @page_hash))

      assert [json] = E.explanation_tags(run.new)
      decoded = Jason.decode!(json)
      assert decoded["explanation"] == valid()
      assert decoded["bundle_hash"] == @page_hash

      assert Map.keys(decoded["explanation"]) |> Enum.sort() == [
               "hypotheses",
               "summary",
               "talking_points"
             ]

      assert run.new == E.expected_page(run.old, json)
    end

    @tag :tmp_dir
    test "names the page as given on the command line", %{tmp_dir: dir} do
      page = Path.relative_to_cwd(E.copy(dir, "page.html"))
      file = E.explanation_file(dir, "valid.json")

      out = E.exec([page, "--apply", file])

      assert out.result == :ok
      assert out.stdout == applied_line(page)
    end

    @tag :tmp_dir
    test "makes the default mode report the page as explained", %{tmp_dir: dir} do
      run = assert_applied(dir, "valid.json")
      before = E.tree(dir)

      out = E.exec([run.page])

      assert out.result == :ok
      assert out.stderr == ""

      assert out.stdout ==
               "#{run.page} is already explained (bundle #{@page_hash}, prompt version 1)\n"

      assert E.tree(dir) == before
    end

    @tag :tmp_dir
    test "text with a closing script tag round-trips and leaves one tag of each id", %{
      tmp_dir: dir
    } do
      plain = assert_applied(dir, "valid.json")
      File.rm!(plain.page)
      breakout = assert_applied(dir, "script_breakout.json")

      assert E.tag_count(breakout.new, "pd-bundle") == 1
      assert E.tag_count(breakout.new, "pd-explanation") == 1
      assert E.close_count(breakout.new) == E.close_count(plain.new)
      assert [json] = E.explanation_tags(breakout.new)
      refute String.contains?(json, "</script>")
      assert String.contains?(json, "<\\/script>")

      sent =
        E.explanation_fixture("script_breakout.json")["hypotheses"] |> hd() |> Map.fetch!("claim")

      stored =
        json |> Jason.decode!() |> get_in(["explanation", "hypotheses", Access.at(0), "claim"])

      assert stored == sent
      assert sent =~ "</script><script>alert(1)</script>"
      assert breakout.new == E.expected_page(breakout.old, json)
    end
  end

  describe "an earlier explanation" do
    @tag :tmp_dir
    test "is replaced, not duplicated, across two applies", %{tmp_dir: dir} do
      first = assert_applied(dir, "valid.json")

      second_spec =
        hyp(valid(), 0, &Map.put(&1, "claim", "The test probably sends the wrong sign."))

      second = assert_applied(dir, second_spec, page: first.page)

      assert E.tag_count(second.new, "pd-explanation") == 1
      assert [json] = E.explanation_tags(second.new)
      assert Jason.decode!(json)["explanation"] == second_spec
      assert second.new == E.expected_page(first.old, json)
      refute String.contains?(second.new, "probably sends a negative amount")
    end

    @tag :tmp_dir
    test "with another hash is replaced and the page then counts as explained", %{tmp_dir: dir} do
      html = E.with_tag_after_bundle(E.fixture("page.html"), @old_explanation)
      page = E.write(dir, "page.html", html)

      run = assert_applied(dir, "valid.json", page: page)

      assert [json] = E.explanation_tags(run.new)
      assert Jason.decode!(json)["bundle_hash"] == @page_hash
      assert run.new == E.expected_page(E.fixture("page.html"), json)

      out = E.exec([page])
      assert out.result == :ok

      assert out.stdout ==
               "#{page} is already explained (bundle #{@page_hash}, prompt version 1)\n"
    end

    @tag :tmp_dir
    test "is removed wherever it sits, with the bytes around it kept", %{tmp_dir: dir} do
      html =
        E.fixture("page.html")
        |> E.with_tag_after_bundle(@old_explanation)
        |> E.with_text_before_body_end("\n" <> E.tag(~s({"second":true})) <> "\n")

      assert length(E.explanation_tags(html)) == 2
      page = E.write(dir, "page.html", html)

      run = assert_applied(dir, "valid.json", page: page)

      assert [json] = E.explanation_tags(run.new)
      assert run.new == E.expected_page(html, json)
      assert String.contains?(run.new, "\n</body>")
    end
  end
end
