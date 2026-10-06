defmodule PropertyDamage.StutterUsingTest do
  # Stutter compares a command's retry events with its original events under
  # `using:`, the same predicate contract as `@compare`: a 2-arity function
  # called `using.(original_events, retry_events)` that returns `:match`,
  # `{:mismatch, exception}`, `{:mismatch, "text"}` or a boolean, `&==/2` when
  # absent. The `comparison:` modes are gone.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, Shrinker}
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.Compare.{AcceptableModel, Paid, PayModel, StutterAdapter}

  defp target(retry), do: {StutterAdapter, name: "s", config: %{test_pid: self(), retry: retry}}

  defp run(retry, stutter, extra \\ []) do
    Compare.run(
      Keyword.get(extra, :model, PayModel),
      [target(retry)],
      [max_commands: 1, stutter: [probability: 1.0, max_repeats: 1, delay_ms: 0] ++ stutter] ++
        Keyword.delete(extra, :model)
    )
  end

  defp violation!(retry, stutter) do
    assert {:error, report} = run(retry, stutter)
    assert report.kind == :check_failed
    assert Failure.kind(report.failure_reason) == :idempotency_violation
    report
  end

  # The mismatch detail recorded anywhere in the violation.
  defp detail(report, match?) do
    found = Compare.deep_find(Failure.detail(report.failure_reason), match?)
    assert found, "no mismatch detail in #{inspect(Failure.detail(report.failure_reason))}"
    found
  end

  defp stutter_error(stutter, extra \\ []) do
    error = Compare.raised(fn -> run(:same, stutter, extra) end)
    refute_received {:setup, _name}
    Exception.message(error)
  end

  describe "removed comparison modes" do
    for {label, mode} <- [
          {":strict", :strict},
          {"{:structural, fields}", {:structural, [:by]}},
          {"{:custom, fun}", {:custom, &Kernel.==/2}},
          {":acceptable", :acceptable}
        ] do
      test "comparison: #{label} is an option error naming using:" do
        assert stutter_error(comparison: unquote(Macro.escape(mode))) =~ "using:"
      end
    end

    test "the command spec key acceptable_retry_events: is an error naming using:" do
      message = stutter_error([], model: AcceptableModel)
      assert message =~ "acceptable_retry_events"
      assert message =~ "using:"
    end

    test "acceptable_retry_events: on use PropertyDamage.Command is rejected naming using:" do
      name = "AcceptableCommand#{System.unique_integer([:positive])}"
      command = Module.concat(__MODULE__, name)

      source = """
      defmodule #{inspect(command)} do
        use PropertyDamage.Command, acceptable_retry_events: [PropertyDamage.Test.Compare.Paid]
        defstruct [:n]

        @impl true
        def generator(_overrides \\\\ %{}), do: StreamData.constant(%{n: 0})
      end
      """

      case Compare.compile(source) do
        {:error, message} ->
          assert message =~ "using:"

        {:ok, _modules} ->
          model = Module.concat([__MODULE__, "Model", name])

          Code.compile_quoted(
            quote do
              defmodule unquote(model) do
                @behaviour PropertyDamage.Model
                def commands, do: [unquote(command)]
                def command_sequence_projection, do: PropertyDamage.Test.Compare.Counter
              end
            end
          )

          assert stutter_error([], model: model) =~ "using:"
      end
    end

    test "a using: that is not a 2-arity function is an option error naming using:" do
      assert stutter_error(using: fn events -> events end) =~ "using:"
    end
  end

  describe "using:" do
    test "is called with the original events, then the retry events" do
      test_pid = self()

      assert {:ok, _stats} =
               run(:different,
                 using: fn original, retry ->
                   send(test_pid, {:stutter_using, original, retry})
                   true
                 end
               )

      assert_received {:stutter_using, [%Paid{by: "first"}], [%Paid{by: "retry"}]}
    end

    test ":match agrees and the default is ==" do
      assert {:ok, _stats} = run(:different, using: fn _original, _retry -> :match end)
      assert {:ok, _stats} = run(:same, [])
      assert {:error, _report} = run(:different, [])
    end

    test "without using:, a differing retry is a mismatch holding original and retry, and the report says so" do
      report = violation!(:different, [])

      mismatch = detail(report, &Compare.mismatch?/1)
      assert [%Paid{by: "first"}] = mismatch.left
      assert [%Paid{by: "retry"}] = mismatch.right

      text = Compare.text(report)
      assert text =~ ~r/original/i
      assert text =~ ~r/retry/i
    end

    test "false becomes a mismatch holding original and retry" do
      report = violation!(:different, using: fn _original, _retry -> false end)

      mismatch = detail(report, &Compare.mismatch?/1)
      assert [%Paid{by: "first", amount: amount}] = mismatch.left
      assert [%Paid{by: "retry", amount: ^amount}] = mismatch.right
    end

    test "{:mismatch, text} becomes a mismatch with that message" do
      report =
        violation!(:different, using: fn _original, _retry -> {:mismatch, "retry differs"} end)

      mismatch = detail(report, &Compare.mismatch?/1)
      assert Exception.message(mismatch) == "retry differs"
    end

    test "{:mismatch, exception} keeps the exception" do
      report =
        violation!(:different,
          using: fn _original, _retry ->
            {:mismatch, %ArgumentError{message: "not idempotent"}}
          end
        )

      assert detail(report, &match?(%ArgumentError{}, &1)).message == "not idempotent"
    end

    test "a violation keeps its shrinker identity" do
      report = violation!(:different, [])

      assert Shrinker.failure_signature(report.failure_reason, report.variant.index) ==
               {:idempotency_violation, nil, 0}
    end
  end
end
