defmodule PropertyDamage.ExportTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Export, FailureReport, Ref, Sequence}
  alias PropertyDamage.Export.HTTPSpec

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  defmodule CreateAccount do
    defstruct [:currency]
  end

  defmodule CreditAccount do
    defstruct [:account_ref, :amount]
  end

  defmodule DebitAccount do
    defstruct [:account_ref, :amount]
  end

  defmodule AccountCreated do
    defstruct [:account_id, :currency]
  end

  defmodule CreditSucceeded do
    defstruct [:account_id, :new_balance]
  end

  defmodule DebitFailed do
    defstruct [:account_id, :reason]
  end

  defmodule TestHTTPAdapter do
    use PropertyDamage.Adapter, default_timeout: 30

    def setup(_config), do: {:ok, %{}}
    def teardown(_context), do: :ok
    def execute(_cmd, _context), do: {:ok, []}

    def http_spec(%CreateAccount{currency: currency}, _ctx) do
      %HTTPSpec{
        method: :post,
        path: "/api/accounts",
        body: %{currency: currency}
      }
    end

    def http_spec(%CreditAccount{account_ref: ref, amount: amount}, _ctx) do
      %HTTPSpec{
        method: :post,
        path: "/api/accounts/:account_id/credit",
        path_params: %{account_id: ref},
        body: %{amount: amount}
      }
    end

    def http_spec(%DebitAccount{account_ref: ref, amount: amount}, _ctx) do
      %HTTPSpec{
        method: :post,
        path: "/api/accounts/:account_id/debit",
        path_params: %{account_id: ref},
        body: %{amount: amount}
      }
    end
  end

  defmodule TestModelStub do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [CreateAccount]
    @impl true
    def command_sequence_projection, do: __MODULE__
  end

  # A command carrying a value with no source literal (a PID).
  defmodule PidCommand do
    defstruct [:pid, :name]
  end

  defp create_test_failure_report do
    account_ref = Ref.symbolic(label: "account")

    commands = [
      %CreateAccount{currency: :USD},
      %CreditAccount{account_ref: account_ref, amount: 100},
      %DebitAccount{account_ref: account_ref, amount: 200}
    ]

    %FailureReport{
      seed: 512_902_757,
      run_number: 1,
      failed_at_index: 2,
      failure_type: :check_failed,
      failure_message: "Balance cannot be negative",
      check_name: :NonNegativeBalance,
      original_sequence: %Sequence{prefix: commands, branches: nil, suffix: []},
      shrunk_sequence: %Sequence{prefix: commands, branches: nil, suffix: []},
      timestamp: ~U[2025-12-26 14:30:00Z],
      model: TestModel,
      adapter: TestHTTPAdapter
    }
  end

  # ============================================================================
  # HTTPSpec Tests
  # ============================================================================

  describe "HTTPSpec" do
    test "creates a new spec" do
      spec = HTTPSpec.new(method: :post, path: "/api/accounts", body: %{currency: "USD"})

      assert spec.method == :post
      assert spec.path == "/api/accounts"
      assert spec.body == %{currency: "USD"}
    end

    test "resolves path parameters" do
      spec = %HTTPSpec{
        method: :get,
        path: "/api/accounts/:account_id/transactions/:tx_id",
        path_params: %{account_id: "acc_123", tx_id: "tx_456"}
      }

      assert HTTPSpec.resolve_path(spec) == "/api/accounts/acc_123/transactions/tx_456"
    end

    test "builds full URL with query params" do
      spec = %HTTPSpec{
        method: :get,
        path: "/api/accounts",
        query_params: %{page: 1, limit: 10}
      }

      url = HTTPSpec.build_url(spec, "http://localhost:4000")
      assert url =~ "http://localhost:4000/api/accounts?"
      assert url =~ "page=1"
      assert url =~ "limit=10"
    end

    test "method_string returns uppercase" do
      spec = %HTTPSpec{method: :post, path: "/test"}
      assert HTTPSpec.method_string(spec) == "POST"
    end

    test "has_body? detects body presence" do
      assert HTTPSpec.has_body?(%HTTPSpec{method: :post, path: "/", body: %{a: 1}})
      refute HTTPSpec.has_body?(%HTTPSpec{method: :get, path: "/", body: nil})
      refute HTTPSpec.has_body?(%HTTPSpec{method: :get, path: "/", body: %{}})
    end
  end

  # ============================================================================
  # Script Export Tests
  # ============================================================================

  describe "to_script/3 - curl" do
    test "generates a bash script with curl commands" do
      failure = create_test_failure_report()

      script =
        Export.to_script(failure, :curl,
          base_url: "http://localhost:4000",
          adapter: TestHTTPAdapter
        )

      assert script =~ "#!/bin/bash"
      assert script =~ "Seed: 512902757"
      assert script =~ "curl -s"
      assert script =~ "BASE_URL"
      assert script =~ "/api/accounts"
      assert script =~ "CreateAccount"
      assert script =~ "CreditAccount"
      assert script =~ "DebitAccount"
      assert script =~ "FAILURE POINT"
    end

    test "includes jq for JSON parsing" do
      failure = create_test_failure_report()

      script =
        Export.to_script(failure, :curl,
          base_url: "http://localhost:4000",
          adapter: TestHTTPAdapter
        )

      assert script =~ "jq -r"
    end
  end

  describe "to_script/3 - elixir" do
    test "generates an elixir script with Req" do
      failure = create_test_failure_report()

      script =
        Export.to_script(failure, :elixir,
          base_url: "http://localhost:4000",
          adapter: TestHTTPAdapter
        )

      assert script =~ "#!/usr/bin/env elixir"
      assert script =~ "Mix.install"
      assert script =~ "{:req"
      assert script =~ "Req.post!"
      assert script =~ "base_url"
      assert script =~ "refs = %{}"
      assert script =~ "FAILURE POINT"
    end

    test "extracts refs from create commands" do
      failure = create_test_failure_report()

      script =
        Export.to_script(failure, :elixir,
          base_url: "http://localhost:4000",
          adapter: TestHTTPAdapter
        )

      assert script =~ "Map.put(refs"
      assert script =~ "Bound ref"
    end
  end

  describe "to_script/3 - python" do
    test "generates a python script with requests" do
      failure = create_test_failure_report()

      script =
        Export.to_script(failure, :python,
          base_url: "http://localhost:4000",
          adapter: TestHTTPAdapter
        )

      assert script =~ "#!/usr/bin/env python3"
      assert script =~ "import requests"
      assert script =~ "requests.post"
      assert script =~ "base_url = os.environ.get"
      assert script =~ "refs = {}"
      assert script =~ "FAILURE POINT"
    end
  end

  # ============================================================================
  # ExUnit Export Tests
  # ============================================================================

  describe "to_exunit/2" do
    test "generates an ExUnit test module" do
      failure = create_test_failure_report()

      test_code = Export.to_exunit(failure)

      assert test_code =~ "defmodule"
      assert test_code =~ "use ExUnit.Case"
      assert test_code =~ "@tag :regression"
      assert test_code =~ "@tag seed: 512902757"
      assert test_code =~ "test"
      assert test_code =~ "PropertyDamage.run"
      assert test_code =~ "NonNegativeBalance"
    end

    test "includes command sequence" do
      failure = create_test_failure_report()

      test_code = Export.to_exunit(failure)

      assert test_code =~ "CreateAccount"
      assert test_code =~ "CreditAccount"
      assert test_code =~ "DebitAccount"
    end

    test "respects custom module name" do
      failure = create_test_failure_report()

      test_code = Export.to_exunit(failure, module_name: MyApp.Regressions.CustomTest)

      assert test_code =~ "MyApp.Regressions.CustomTest"
    end

    test "a command with a non-literal field (PID) does not emit invalid #PID<> source" do
      account_ref = Ref.symbolic(label: "account")

      commands = [%PidCommand{pid: self(), name: "worker"}]

      failure = %FailureReport{
        seed: 123,
        failure_type: :check_failed,
        check_name: :NonNegativeBalance,
        failure_message: "boom",
        original_sequence: %Sequence{prefix: commands, branches: nil, suffix: []},
        shrunk_sequence: %Sequence{prefix: commands, branches: nil, suffix: []},
        model: TestModelStub,
        adapter: TestHTTPAdapter
      }

      _ = account_ref
      code = Export.to_exunit(failure, module_name: PDExportPidCheck)

      refute code =~ "#PID"
      refute code =~ "#Reference"
      # parses as valid Elixir (the #PID<...> literal would be a syntax error)
      assert {:ok, _ast} = Code.string_to_quoted(code)
    end

    test "the generated test body compiles clean (no unused-var/#PID diagnostics)" do
      failure = %{create_test_failure_report() | model: TestModelStub}

      code = Export.to_exunit(failure, module_name: PDExportWaeCheck)

      # Compile the generated body as a plain function rather than an ExUnit
      # test, so we get its compiler diagnostics (unused vars, bad literals)
      # without the `use ExUnit.Case` module being registered and run.
      compilable =
        code
        |> String.replace("use ExUnit.Case, async: true", "import ExUnit.Assertions")
        |> String.replace(~r/\n\s*@tag [^\n]+/, "")
        |> String.replace(~r/test "[^"]+" do/, "def __regression_check__ do")

      {_result, diagnostics} =
        Code.with_diagnostics(fn ->
          try do
            Code.compile_string(compilable)
          rescue
            e -> e
          end
        end)

      assert diagnostics == [],
             "generated test body emitted compiler diagnostics:\n" <>
               Enum.map_join(diagnostics, "\n", &inspect/1)

      :code.purge(PDExportWaeCheck)
      :code.delete(PDExportWaeCheck)
    end
  end

  # ============================================================================
  # LiveBook Export Tests
  # ============================================================================

  describe "to_livebook/2" do
    test "generates a LiveBook notebook" do
      failure = create_test_failure_report()

      notebook =
        Export.to_livebook(failure,
          base_url: "http://localhost:4000",
          adapter: TestHTTPAdapter
        )

      assert notebook =~ "# Failure Investigation"
      assert notebook =~ "```elixir"
      assert notebook =~ "Mix.install"
      assert notebook =~ "state = %{refs: %{}"
      assert notebook =~ "## Command Sequence"
      assert notebook =~ "Step 1:"
      assert notebook =~ "Step 2:"
      assert notebook =~ "Step 3:"
      assert notebook =~ "FAILURE"
    end

    test "includes exploration section by default" do
      failure = create_test_failure_report()

      notebook =
        Export.to_livebook(failure,
          base_url: "http://localhost:4000",
          adapter: TestHTTPAdapter
        )

      assert notebook =~ "## Exploration"
      assert notebook =~ "What to Try"
    end

    test "can exclude exploration section" do
      failure = create_test_failure_report()

      notebook =
        Export.to_livebook(failure,
          base_url: "http://localhost:4000",
          adapter: TestHTTPAdapter,
          include_exploration: false
        )

      refute notebook =~ "## Exploration"
    end
  end

  # ============================================================================
  # File Operations Tests
  # ============================================================================

  describe "save/4" do
    @tag :tmp_dir
    test "saves export to file", %{tmp_dir: tmp_dir} do
      failure = create_test_failure_report()

      {:ok, path} = Export.save(failure, tmp_dir, :exunit)

      assert File.exists?(path)
      assert path =~ ~r/reproduce_512902757_[0-9a-f]+\.exs$/

      content = File.read!(path)
      assert content =~ "defmodule"
    end

    @tag :tmp_dir
    test "saves script to file with correct extension", %{tmp_dir: tmp_dir} do
      failure = create_test_failure_report()

      {:ok, curl_path} =
        Export.save(failure, tmp_dir, {:script, :curl},
          base_url: "http://localhost:4000",
          adapter: TestHTTPAdapter
        )

      {:ok, python_path} =
        Export.save(failure, tmp_dir, {:script, :python},
          base_url: "http://localhost:4000",
          adapter: TestHTTPAdapter
        )

      assert curl_path =~ ".sh"
      assert python_path =~ ".py"
    end
  end

  describe "save_all/3" do
    @tag :tmp_dir
    test "saves all formats", %{tmp_dir: tmp_dir} do
      failure = create_test_failure_report()

      {:ok, paths} =
        Export.save_all(failure, tmp_dir,
          base_url: "http://localhost:4000",
          adapter: TestHTTPAdapter,
          script_languages: [:elixir, :curl]
        )

      assert Map.has_key?(paths, :exunit)
      assert Map.has_key?(paths, :livebook)
      assert Map.has_key?(paths, :script_elixir)
      assert Map.has_key?(paths, :script_curl)

      # Verify files exist
      Enum.each(Map.values(paths), fn path ->
        assert File.exists?(path), "Expected file to exist: #{path}"
      end)
    end
  end

  # ============================================================================
  # Common Module Tests
  # ============================================================================

  describe "Export.Common" do
    alias PropertyDamage.Export.Common

    test "extracts commands from failure report" do
      failure = create_test_failure_report()

      commands = Common.extract_commands(failure)

      assert length(commands) == 3
      assert match?(%CreateAccount{}, hd(commands))
    end

    test "generates filename based on seed" do
      failure = create_test_failure_report()

      assert Common.generate_filename(failure, :exunit) =~
               ~r/^reproduce_512902757_[0-9a-f]+\.exs$/

      assert Common.generate_filename(failure, :curl) =~ ~r/^reproduce_512902757_[0-9a-f]+\.sh$/
      assert Common.generate_filename(failure, :python) =~ ~r/^reproduce_512902757_[0-9a-f]+\.py$/

      assert Common.generate_filename(failure, :livebook) =~
               ~r/^reproduce_512902757_[0-9a-f]+\.livemd$/

      # stable for the same failure, distinct for a different one
      assert Common.generate_filename(failure, :exunit) ==
               Common.generate_filename(failure, :exunit)

      other = %{failure | failure_reason: {:check_failed, :Other, "different"}}

      refute Common.generate_filename(other, :exunit) ==
               Common.generate_filename(failure, :exunit)
    end

    test "command_name extracts last part of module" do
      cmd = %CreateAccount{currency: :USD}
      assert Common.command_name(cmd) == "CreateAccount"
    end

    test "command_to_comment formats command readably" do
      cmd = %CreateAccount{currency: :USD}
      comment = Common.command_to_comment(cmd)

      assert comment =~ "CreateAccount"
      assert comment =~ "currency"
    end
  end
end
