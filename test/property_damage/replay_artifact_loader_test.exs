defmodule PropertyDamage.ReplayArtifactLoaderTest do
  # The replay artifact loader reads a file as data: it parses the source and
  # accepts literals only (atoms, booleans, nil, numbers, strings, charlists,
  # lists, tuples, maps, keyword lists and struct literals of loaded command
  # modules and of the framework's placeholders). Anything that would run
  # code, and any header or format it does not know, is refused with a reason
  # naming the node (and, for a node, its line). Nothing in the file is ever
  # evaluated.
  use ExUnit.Case, async: true

  alias PropertyDamage.Placeholder
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.ReplayFixtures, as: R

  @header "# PropertyDamage replay artifact, format 1"
  @marker "PAYLOAD_SOURCE"

  # A complete artifact for CleanModel whose one leaf holds `payload` (Elixir
  # source) on a line of its own.
  defp template(opts \\ []) do
    header = Keyword.get(opts, :header, @header)
    format = Keyword.get(opts, :format, 1)

    """
    #{header}
    # model: PropertyDamage.Test.ReplayFixtures.CleanModel
    # seed: 7
    # run: 1
    # target "ref" (reference), expansion: :random
    %{
      choices: %{
        "ref" => [
          # root 0: Mark[0] = [Tag]
          %{
            aliases: %{},
            commands: [
              %PropertyDamage.Test.ReplayFixtures.Tag{
                n: 1,
                payload:
                  #{@marker}
              }
            ],
            entry: "Mark[0]",
            root_id: 0
          }
        ]
      },
      failure: %{
        kind: :diverged,
        name: {PropertyDamage.Test.ReplayFixtures.Tally, :total},
        root_index: 0,
        variant_index: 0
      },
      format: #{format},
      model: PropertyDamage.Test.ReplayFixtures.CleanModel,
      prefix: [],
      roots: [
        # root 0: Mark
        %{command: %PropertyDamage.Test.ReplayFixtures.Mark{n: 1}, root_id: 0}
      ],
      run: 1,
      seed: 7,
      targets: [%{expansion: :random, name: "ref"}]
    }
    """
  end

  defp artifact(payload, opts \\ []), do: String.replace(template(opts), @marker, payload)

  # The 1-based line the payload starts on.
  defp payload_line do
    index = template() |> String.split("\n") |> Enum.find_index(&String.contains?(&1, @marker))
    index + 1
  end

  defp term_with(payload) do
    %{
      choices: %{
        "ref" => [
          %{
            aliases: %{},
            commands: [%R.Tag{n: 1, payload: payload}],
            entry: "Mark[0]",
            root_id: 0
          }
        ]
      },
      failure: %{kind: :diverged, name: {R.Tally, :total}, root_index: 0, variant_index: 0},
      format: 1,
      model: R.CleanModel,
      prefix: [],
      roots: [%{command: %R.Mark{n: 1}, root_id: 0}],
      run: 1,
      seed: 7,
      targets: [%{expansion: :random, name: "ref"}]
    }
  end

  # The refusal reason for `text`, as text.
  defp refused(text) do
    assert {:error, reason} = R.parse_artifact(text)
    R.reason_text(reason)
  end

  defp assert_names(message, fragments) do
    for fragment <- fragments do
      assert message =~ fragment, "expected the reason to name #{inspect(fragment)}: #{message}"
    end
  end

  describe "accepts" do
    test "every literal kind, with struct literals rebuilt with their defaults" do
      payload = """
      [:atom, :"two words", true, false, nil, 42, -3, 12_345_678_901_234, 1.5, -2.5, "text", [97, 98, 99], {1, 2}, {:a, :b, :c}, %{"k" => [x: 1, y: 2]}, PropertyDamage.Test.ReplayFixtures.Tally, %PropertyDamage.Test.ReplayFixtures.Mark{n: 3}, %PropertyDamage.Test.ReplayFixtures.Mark{}]
      """

      expected = [
        :atom,
        :"two words",
        true,
        false,
        nil,
        42,
        -3,
        12_345_678_901_234,
        1.5,
        -2.5,
        "text",
        ~c"abc",
        {1, 2},
        {:a, :b, :c},
        %{"k" => [x: 1, y: 2]},
        R.Tally,
        %R.Mark{n: 3},
        %R.Mark{n: nil}
      ]

      assert R.parse_artifact(artifact(payload)) == {:ok, term_with(expected)}
    end

    test "a placeholder struct literal, with its id tuple and position" do
      payload = """
      %PropertyDamage.Placeholder{
        id: {%PropertyDamage.Sequence.Position{section: {:leaf, 2}, offset: 1}, 0, [:id]},
        event_module: PropertyDamage.Test.ReplayFixtures.Opened,
        path: [:id],
        position: %PropertyDamage.Sequence.Position{section: {:leaf, 2}, offset: 1},
        event_index: 0,
        resolved: nil
      }
      """

      placeholder = Placeholder.new_at(R.Opened, [:id], Position.leaf(2, 1), 0)
      assert R.parse_artifact(artifact(payload)) == {:ok, term_with(placeholder)}
    end

    test "read/1 reads a file the way parse/1 reads its text" do
      path = Path.join(R.tmp_dir!(), "Clean_seed7.replay.exs")
      text = artifact("[note: \"plain\"]")
      File.write!(path, text)

      assert R.read_artifact(path) == {:ok, term_with(note: "plain")}
      assert R.read_artifact(path) == R.parse_artifact(text)
    end

    test "read/1 of a path that does not exist is an error naming it" do
      path = Path.join(R.tmp_dir!(), "absent.replay.exs")
      assert {:error, reason} = R.read_artifact(path)
      assert R.reason_text(reason) =~ "absent.replay.exs"
    end
  end

  describe "refuses the header" do
    test "when it is missing" do
      text = artifact(":ok") |> String.split("\n") |> tl() |> Enum.join("\n")
      assert_names(refused(text), ["header"])
    end

    test "for another format" do
      header = "# PropertyDamage replay artifact, format 2"
      message = refused(artifact(":ok", header: header, format: 2))
      assert message =~ ~r/format:? 2/
    end

    test "when the term's format disagrees with it" do
      message = refused(artifact(":ok", format: 3))
      assert message =~ "header"
      assert message =~ ~r/format:? 3/
    end
  end

  describe "refuses anything but one literal term" do
    test "a second term after the first" do
      text = artifact(":ok") <> ":second_term\n"
      line = length(String.split(artifact(":ok"), "\n"))
      assert_names(refused(text), ["second_term", "line #{line}"])
    end

    test "a call, without running it" do
      touched = Path.join(R.tmp_dir!(), "touched")
      message = refused(artifact(~s|System.cmd("touch", [#{inspect(touched)}])|))

      assert_names(message, ["System.cmd", "line #{payload_line()}"])
      refute File.exists?(touched)
    end

    test "a call in a file read with read/1, without running it" do
      dir = R.tmp_dir!()
      touched = Path.join(dir, "touched")
      path = Path.join(dir, "Clean_seed7.replay.exs")
      File.write!(path, artifact(~s|System.cmd("touch", [#{inspect(touched)}])|))

      assert {:error, reason} = R.read_artifact(path)
      assert_names(R.reason_text(reason), ["System.cmd", "line #{payload_line()}"])
      refute File.exists?(touched)
    end

    for {name, source, fragment} <- [
          {"a capture", "&IO.puts/1", "IO.puts"},
          {"an anonymous function", "fn -> :ok end", "fn"},
          {"a pipe", "[1, 2] |> Enum.reverse()", "|>"},
          {"a sigil", "~w(a b)", "~w"},
          {"a module attribute", "@secret_attribute", "@secret_attribute"},
          {"a variable", "secret_variable", "secret_variable"}
        ] do
      @source source
      @fragment fragment
      test "#{name}, naming it and its line" do
        assert_names(refused(artifact(@source)), [@fragment, "line #{payload_line()}"])
      end
    end

    # A struct module the artifact may not name is refused naming the module;
    # one whose name is no atom at all is refused as an unknown name, with
    # its line.
    for {name, source, fragment} <- [
          {"a struct literal of a module that is not loaded",
           "%PropertyDamage.Test.ReplayFixtures.NoSuchModule{n: 1}",
           "PropertyDamage.Test.ReplayFixtures.NoSuchModule"},
          {"a struct literal of a module that is not a struct",
           "%PropertyDamage.Test.ReplayFixtures.Recorder{}", "ReplayFixtures.Recorder"}
        ] do
      @source source
      @fragment fragment
      test "#{name}, naming it" do
        assert_names(refused(artifact(@source)), [@fragment])
      end
    end
  end

  describe "fixture smoke" do
    test "the template parses as Elixir and holds the payload on its own line" do
      assert {:ok, _quoted} = Code.string_to_quoted(artifact(":ok"))

      assert template() |> String.split("\n") |> Enum.at(payload_line() - 1) |> String.trim() ==
               @marker
    end

    test "the not-a-struct module is loaded and defines no struct" do
      assert Code.ensure_loaded?(R.Recorder)
      refute function_exported?(R.Recorder, :__struct__, 0)
      refute Code.ensure_loaded?(Module.concat(R, NoSuchModule))
    end
  end
end
