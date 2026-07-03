defmodule PropertyDamage.DiagramTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Diagram, EventLog.Entry, FailureReport, Sequence}

  # Test event/command structs
  defmodule TestCommand do
    defstruct [:account_id, :amount]
  end

  defmodule TestEvent do
    defstruct [:id, :balance]
  end

  defmodule AnotherCommand do
    defstruct [:id]
  end

  defmodule AnotherEvent do
    defstruct [:status]
  end

  setup do
    commands = [
      %TestCommand{account_id: "acc_123", amount: 100},
      %AnotherCommand{id: "order_456"}
    ]

    sequence = Sequence.linear(commands)

    event_log = [
      %Entry{
        timestamp: 1000,
        command_index: 0,
        event: %TestEvent{id: "evt_1", balance: 100},
        source: :command
      },
      %Entry{
        timestamp: 2000,
        command_index: 1,
        event: %AnotherEvent{status: :completed},
        source: :command
      }
    ]

    {:ok, sequence: sequence, event_log: event_log, commands: commands}
  end

  describe "generate/4 with Mermaid format" do
    test "generates valid mermaid diagram", %{sequence: sequence, event_log: event_log} do
      diagram = Diagram.generate(sequence, event_log, :mermaid)

      assert String.contains?(diagram, "```mermaid")
      assert String.contains?(diagram, "sequenceDiagram")
      assert String.contains?(diagram, "participant Test")
      assert String.contains?(diagram, "participant SUT")
      assert String.contains?(diagram, "Test->>SUT:")
      assert String.contains?(diagram, "SUT-->>Test:")
      assert String.contains?(diagram, "```")
    end

    test "includes command names and params", %{sequence: sequence, event_log: event_log} do
      diagram = Diagram.generate(sequence, event_log, :mermaid)

      assert String.contains?(diagram, "TestCommand")
      assert String.contains?(diagram, "account_id")
      assert String.contains?(diagram, "AnotherCommand")
    end

    test "includes event names", %{sequence: sequence, event_log: event_log} do
      diagram = Diagram.generate(sequence, event_log, :mermaid)

      assert String.contains?(diagram, "TestEvent")
      assert String.contains?(diagram, "AnotherEvent")
    end

    test "supports custom title", %{sequence: sequence, event_log: event_log} do
      diagram = Diagram.generate(sequence, event_log, :mermaid, title: "My Custom Title")

      assert String.contains?(diagram, "title My Custom Title")
    end

    test "highlights failure point", %{sequence: sequence, event_log: event_log} do
      diagram =
        Diagram.generate(sequence, event_log, :mermaid,
          failed_at_index: 1,
          failure_message: "Balance went negative"
        )

      assert String.contains?(diagram, "FAILURE at command 1")
      assert String.contains?(diagram, "Test-xSUT:")
      assert String.contains?(diagram, "Balance went negative")
    end

    test "includes State participant when show_state is true", %{
      sequence: sequence,
      event_log: event_log
    } do
      diagram = Diagram.generate(sequence, event_log, :mermaid, show_state: true)

      assert String.contains?(diagram, "participant State")
    end
  end

  describe "generate/4 with PlantUML format" do
    test "generates valid plantuml diagram", %{sequence: sequence, event_log: event_log} do
      diagram = Diagram.generate(sequence, event_log, :plantuml)

      assert String.contains?(diagram, "@startuml")
      assert String.contains?(diagram, "@enduml")
      assert String.contains?(diagram, "participant Test")
      assert String.contains?(diagram, "participant SUT")
      assert String.contains?(diagram, "Test -> SUT :")
      assert String.contains?(diagram, "SUT --> Test :")
    end

    test "includes title", %{sequence: sequence, event_log: event_log} do
      diagram = Diagram.generate(sequence, event_log, :plantuml, title: "PlantUML Test")

      assert String.contains?(diagram, "title PlantUML Test")
    end

    test "highlights failure with hnote", %{sequence: sequence, event_log: event_log} do
      diagram =
        Diagram.generate(sequence, event_log, :plantuml,
          failed_at_index: 0,
          failure_message: "Invariant violated"
        )

      assert String.contains?(diagram, "hnote over Test,SUT")
      assert String.contains?(diagram, "FAILURE")
      assert String.contains?(diagram, "Test -x SUT")
    end
  end

  describe "generate/4 with WebSequence format" do
    test "generates valid websequence diagram", %{sequence: sequence, event_log: event_log} do
      diagram = Diagram.generate(sequence, event_log, :websequence)

      assert String.contains?(diagram, "title")
      assert String.contains?(diagram, "Test->SUT:")
      assert String.contains?(diagram, "SUT-->Test:")
    end

    test "highlights failure with note", %{sequence: sequence, event_log: event_log} do
      diagram =
        Diagram.generate(sequence, event_log, :websequence,
          failed_at_index: 1,
          failure_message: "Test failed"
        )

      assert String.contains?(diagram, "note over Test,SUT: FAILURE")
      assert String.contains?(diagram, "note right of SUT: Test failed")
    end
  end

  describe "generate_all/3" do
    test "returns all formats", %{sequence: sequence, event_log: event_log} do
      diagrams = Diagram.generate_all(sequence, event_log)

      assert Map.has_key?(diagrams, :mermaid)
      assert Map.has_key?(diagrams, :plantuml)
      assert Map.has_key?(diagrams, :websequence)

      assert String.contains?(diagrams.mermaid, "```mermaid")
      assert String.contains?(diagrams.plantuml, "@startuml")
      assert String.contains?(diagrams.websequence, "title")
    end
  end

  describe "from_failure_report/3" do
    test "generates diagram from failure report" do
      commands = [
        %TestCommand{account_id: "acc_1", amount: 50},
        %AnotherCommand{id: "order_1"}
      ]

      sequence = Sequence.linear(commands)

      event_log = [
        %Entry{
          timestamp: 1000,
          command_index: 0,
          event: %TestEvent{id: "e1", balance: 50},
          source: :command
        }
      ]

      report = %FailureReport{
        seed: 12_345,
        run_number: 1,
        failed_at_index: 1,
        failure_type: :check_failed,
        original_sequence: sequence,
        failure_reason: {:check_failed, :NonNegativeBalance, "Balance is -50"},
        check_name: :NonNegativeBalance,
        failure_message: "Balance is -50",
        trace: PropertyDamage.RunTrace.new(plan: sequence, event_log: event_log),
        timestamp: DateTime.utc_now()
      }

      diagram = Diagram.from_failure_report(report, :mermaid)

      assert String.contains?(diagram, "sequenceDiagram")
      assert String.contains?(diagram, "12345")
      assert String.contains?(diagram, "FAILURE at command 1")
      assert String.contains?(diagram, "Balance is -50")
    end
  end

  describe "value formatting" do
    test "truncates long values", %{event_log: event_log} do
      long_command = %TestCommand{
        account_id: String.duplicate("a", 100),
        amount: 100
      }

      sequence = Sequence.linear([long_command])

      diagram = Diagram.generate(sequence, event_log, :mermaid, max_value_length: 30)

      # Should be truncated with ...
      assert String.contains?(diagram, "...")
    end
  end

  describe "event sources" do
    test "shows nemesis events with indicator" do
      commands = [%TestCommand{account_id: "acc_1", amount: 100}]
      sequence = Sequence.linear(commands)

      event_log = [
        %Entry{
          timestamp: 1000,
          command_index: 0,
          event: %TestEvent{id: "e1", balance: 100},
          source: :nemesis,
          nemesis_module: SomeNemesis
        }
      ]

      diagram = Diagram.generate(sequence, event_log, :mermaid)

      assert String.contains?(diagram, "[nemesis]")
    end

    test "shows injector events with indicator" do
      commands = [%TestCommand{account_id: "acc_1", amount: 100}]
      sequence = Sequence.linear(commands)

      event_log = [
        %Entry{
          timestamp: 1000,
          command_index: 0,
          event: %TestEvent{id: "e1", balance: 100},
          source: :injector,
          injector_adapter: SomeInjector
        }
      ]

      diagram = Diagram.generate(sequence, event_log, :mermaid)

      assert String.contains?(diagram, "[injected]")
    end
  end

  describe "save/3" do
    @tag :tmp_dir
    test "saves diagram to file", %{sequence: sequence, event_log: event_log, tmp_dir: tmp_dir} do
      diagram = Diagram.generate(sequence, event_log, :mermaid)
      path = Path.join(tmp_dir, "test_diagram")

      assert :ok = Diagram.save(diagram, path, :mermaid)
      assert File.exists?(path <> ".md")

      content = File.read!(path <> ".md")
      assert content == diagram
    end

    @tag :tmp_dir
    test "adds correct extension for each format", %{
      sequence: sequence,
      event_log: event_log,
      tmp_dir: tmp_dir
    } do
      diagram_mermaid = Diagram.generate(sequence, event_log, :mermaid)
      diagram_plantuml = Diagram.generate(sequence, event_log, :plantuml)
      diagram_webseq = Diagram.generate(sequence, event_log, :websequence)

      Diagram.save(diagram_mermaid, Path.join(tmp_dir, "d1"), :mermaid)
      Diagram.save(diagram_plantuml, Path.join(tmp_dir, "d2"), :plantuml)
      Diagram.save(diagram_webseq, Path.join(tmp_dir, "d3"), :websequence)

      assert File.exists?(Path.join(tmp_dir, "d1.md"))
      assert File.exists?(Path.join(tmp_dir, "d2.puml"))
      assert File.exists?(Path.join(tmp_dir, "d3.txt"))
    end
  end

  # ============================================================================
  # Characterization Goldens
  # ============================================================================
  #
  # Byte-for-byte guard for the shared step-builder migration (F3): diagram
  # output must not drift for the report-less generate/4 path or the
  # report-driven from_failure_report/3 path. Re-baseline deliberately with
  # CAPTURE_GOLDENS=1.

  describe "characterization goldens (shared step-builder migration guard)" do
    @golden_dir Path.join([__DIR__, "..", "support", "fixtures", "diagram"])

    defp golden_path(name), do: Path.join(@golden_dir, name)

    defp check_golden(name, actual) do
      if System.get_env("CAPTURE_GOLDENS") == "1" do
        File.mkdir_p!(@golden_dir)
        File.write!(golden_path(name), actual)
        assert true
      else
        expected = File.read!(golden_path(name))

        assert actual == expected,
               "#{name} drifted from golden. Re-baseline with CAPTURE_GOLDENS=1 only if the change is intended."
      end
    end

    defp report_fixture do
      commands = [
        %TestCommand{account_id: "acc_1", amount: 50},
        %AnotherCommand{id: "order_1"}
      ]

      sequence = Sequence.linear(commands)

      event_log = [
        %Entry{
          timestamp: 1000,
          command_index: 0,
          event: %TestEvent{id: "e1", balance: 50},
          source: :command
        }
      ]

      %FailureReport{
        seed: 12_345,
        run_number: 1,
        failed_at_index: 1,
        failure_type: :check_failed,
        original_sequence: sequence,
        failure_reason: {:check_failed, :NonNegativeBalance, "Balance is -50"},
        check_name: :NonNegativeBalance,
        failure_message: "Balance is -50",
        trace: PropertyDamage.RunTrace.new(plan: sequence, event_log: event_log),
        timestamp: ~U[2025-01-01 00:00:00Z]
      }
    end

    for {format, ext} <- [{:mermaid, "mmd"}, {:plantuml, "puml"}, {:websequence, "wsd"}] do
      test "generate/4 #{format} is byte-identical", %{
        sequence: sequence,
        event_log: event_log
      } do
        actual =
          Diagram.generate(sequence, event_log, unquote(format),
            title: "Fixture",
            show_state: true
          )

        check_golden("generate.#{unquote(ext)}", actual)
      end

      test "from_failure_report/3 #{format} is byte-identical" do
        actual = Diagram.from_failure_report(report_fixture(), unquote(format))
        check_golden("from_report.#{unquote(ext)}", actual)
      end
    end
  end
end
