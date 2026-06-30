defmodule PropertyDamage.ErrorOrigin do
  @moduledoc """
  Classifies test failures by their likely origin.

  When a PropertyDamage test fails, the failure can come from:

  - **SUT Error**: A bug in the System Under Test (what we're trying to find)
  - **Test Code Error**: A bug in the test configuration (model, projections, commands, adapters)

  This module analyzes failure reasons and stacktraces to determine the most likely origin,
  helping users quickly understand whether they need to fix their SUT or their test code.

  ## Classification Categories

  ### SUT Errors (High Confidence)

  These failures almost certainly indicate bugs in the SUT:

  - `:check_failed` / `:assertion_failed` - Invariant violations
  - `:poll_timeout` - Temporal assertion timeout
  - `:idempotency_violation` - SUT not idempotent
  - `:linearization_failed` - Race condition detected

  ### Test Code Errors (High Confidence)

  These failures almost certainly indicate bugs in test code:

  - `UndefinedFunctionError` in model/projection/command/adapter modules
  - `FunctionClauseError` in projection.apply/2 or command callbacks
  - Missing required callbacks
  - Module compilation errors

  ### Ambiguous

  These failures could be either:

  - Generic exceptions during assertion execution
  - Adapter errors (could be bad adapter code or SUT returning unexpected data)
  """

  @type origin :: :sut_error | :test_code_error | :unknown

  @type details :: %{
          reason: String.t(),
          evidence: map(),
          confidence: :high | :medium | :low
        }

  @type classification :: %{
          origin: origin(),
          details: details()
        }

  @doc """
  Classify a failure by its likely origin.

  Takes a failure reason and optional stacktrace, returns classification.

  ## Examples

      iex> ErrorOrigin.classify({:check_failed, :NonNegativeBalance, "Balance is -50"})
      %{origin: :sut_error, details: %{reason: "Invariant violation", ...}}

      iex> ErrorOrigin.classify({:adapter_error, %UndefinedFunctionError{...}}, stacktrace)
      %{origin: :test_code_error, details: %{reason: "Missing callback", ...}}
  """
  @spec classify(term(), list() | nil) :: classification()
  def classify(failure_reason, stacktrace \\ nil)

  # ============================================================================
  # SUT Errors (High Confidence)
  # ============================================================================

  def classify({:check_failed, check_name, message}, _stacktrace) do
    %{
      origin: :sut_error,
      details: %{
        reason: "Invariant '#{check_name}' violated",
        evidence: %{check_name: check_name, message: message},
        confidence: :high
      }
    }
  end

  def classify({:assertion_failed, assertion_name, reason}, _stacktrace) do
    if assertion_code_crash?(reason) do
      # The assertion function itself raised an unexpected exception (e.g. a
      # KeyError on a missing field) rather than calling fail!/raising
      # AssertionFailed. That is a bug in the assertion code, not the SUT.
      %{
        origin: :test_code_error,
        details: %{
          reason: "Assertion '#{assertion_name}' raised an unexpected exception",
          evidence: %{
            assertion_name: assertion_name,
            reason: format_reason(reason),
            hint:
              "The assertion code crashed. Fix the assertion (or call " <>
                "PropertyDamage.fail!/2 to report a real SUT violation)."
          },
          confidence: :high
        }
      }
    else
      %{
        origin: :sut_error,
        details: %{
          reason: "Assertion '#{assertion_name}' failed",
          evidence: %{assertion_name: assertion_name, reason: format_reason(reason)},
          confidence: :high
        }
      }
    end
  end

  def classify({:poll_timeout, info}, _stacktrace) do
    %{
      origin: :sut_error,
      details: %{
        reason: "Temporal assertion timed out waiting for condition",
        evidence: %{
          assertion_name: get_in(info, [:triggered_by, :assertion_name]),
          timeout_ms: Map.get(info, :elapsed_ms),
          poll_count: Map.get(info, :poll_count)
        },
        confidence: :high
      }
    }
  end

  def classify({:idempotency_violation, violation}, _stacktrace) do
    %{
      origin: :sut_error,
      details: %{
        reason: "Command not idempotent - produced different results on retry",
        evidence: %{
          command: get_command_name(violation),
          attempts: Map.get(violation, :attempts),
          comparison: Map.get(violation, :comparison_result)
        },
        confidence: :high
      }
    }
  end

  def classify({:linearization_failed, message}, _stacktrace) do
    %{
      origin: :sut_error,
      details: %{
        reason: "Race condition - no valid linearization exists",
        evidence: %{message: message},
        confidence: :high
      }
    }
  end

  # ============================================================================
  # Test Code Errors (High Confidence)
  # ============================================================================

  def classify({:adapter_error, %UndefinedFunctionError{} = error}, stacktrace) do
    classify_undefined_function_error(error, stacktrace, :adapter_error)
  end

  def classify({:adapter_error, %FunctionClauseError{} = error}, stacktrace) do
    classify_function_clause_error(error, stacktrace, :adapter_error)
  end

  def classify({:adapter_error, %ArgumentError{} = error}, stacktrace) do
    classify_argument_error(error, stacktrace, :adapter_error)
  end

  def classify({:ref_resolution_error, reason}, _stacktrace) do
    # Ref resolution errors are almost always test code errors
    %{
      origin: :test_code_error,
      details: %{
        reason: "Ref resolution failed - check command dependencies",
        evidence: %{reason: reason},
        confidence: :high
      }
    }
  end

  # Check for wrapped exceptions in generic adapter errors
  # (UndefinedFunctionError, FunctionClauseError, and ArgumentError are already
  # handled by the dedicated clauses above)
  def classify({:adapter_error, reason}, stacktrace) when is_exception(reason) do
    case reason do
      %KeyError{} = e ->
        # KeyError during adapter execution - likely test code error
        %{
          origin: :test_code_error,
          details: %{
            reason: "Missing key '#{e.key}' in adapter code",
            evidence: %{key: e.key, term: inspect(e.term, limit: 3)},
            confidence: :medium
          }
        }

      _ ->
        classify_generic_exception(reason, stacktrace)
    end
  end

  # ============================================================================
  # Branch Failures - Recurse into inner reason
  # ============================================================================

  def classify({:branch_failure, branch_id, inner_reason}, stacktrace) do
    inner = classify(inner_reason, stacktrace)

    %{
      inner
      | details:
          Map.merge(inner.details, %{
            branch_id: branch_id,
            context: "Failure occurred in branch #{branch_id}"
          })
    }
  end

  # ============================================================================
  # Generic/Ambiguous Cases
  # ============================================================================

  def classify({:adapter_error, reason}, _stacktrace) do
    %{
      origin: :unknown,
      details: %{
        reason: "Adapter error - could be SUT or test code",
        evidence: %{reason: inspect(reason)},
        confidence: :low
      }
    }
  end

  def classify({:settle_timeout, reason}, _stacktrace) do
    %{
      origin: :unknown,
      details: %{
        reason: "Command timed out waiting to settle",
        evidence: %{last_reason: inspect(reason)},
        confidence: :low
      }
    }
  end

  def classify({:nemesis_error, reason}, _stacktrace) do
    %{
      origin: :test_code_error,
      details: %{
        reason: "Nemesis (fault injection) command failed",
        evidence: %{reason: inspect(reason)},
        confidence: :medium
      }
    }
  end

  def classify({:stutter_execution_failed, details}, _stacktrace) do
    %{
      origin: :unknown,
      details: %{
        reason: "Stutter retry execution failed",
        evidence: details,
        confidence: :low
      }
    }
  end

  def classify(other, _stacktrace) do
    %{
      origin: :unknown,
      details: %{
        reason: "Unclassified failure",
        evidence: %{raw: inspect(other)},
        confidence: :low
      }
    }
  end

  # ============================================================================
  # Exception Classification Helpers
  # ============================================================================

  defp classify_undefined_function_error(error, stacktrace, _context) do
    module = error.module
    function = error.function
    arity = error.arity

    test_code_module? = test_code_module?(module, stacktrace)

    if test_code_module? do
      %{
        origin: :test_code_error,
        details: %{
          reason: "Missing function #{inspect(module)}.#{function}/#{arity}",
          evidence: %{
            module: module,
            function: function,
            arity: arity,
            hint: suggest_fix_for_undefined_function(module, function, arity)
          },
          confidence: :high
        }
      }
    else
      %{
        origin: :unknown,
        details: %{
          reason: "Undefined function #{inspect(module)}.#{function}/#{arity}",
          evidence: %{module: module, function: function, arity: arity},
          confidence: :medium
        }
      }
    end
  end

  defp classify_function_clause_error(error, stacktrace, _context) do
    # Extract module from stacktrace if available
    module = extract_module_from_function_clause_error(error, stacktrace)
    test_code_module? = test_code_module?(module, stacktrace)

    if test_code_module? do
      %{
        origin: :test_code_error,
        details: %{
          reason: "No function clause matched in #{module_name(module)}",
          evidence: %{
            module: module,
            args: inspect(error.args, limit: 3),
            hint: "Check your projection's apply/2 function handles all command/event types"
          },
          confidence: :high
        }
      }
    else
      %{
        origin: :unknown,
        details: %{
          reason: "No function clause matched",
          evidence: %{module: module, args: inspect(error.args, limit: 3)},
          confidence: :medium
        }
      }
    end
  end

  defp classify_argument_error(error, stacktrace, _context) do
    # Check if this looks like a test code configuration error
    message = Exception.message(error)

    cond do
      message =~ ~r/argument error.*struct/i ->
        %{
          origin: :test_code_error,
          details: %{
            reason: "Invalid struct construction",
            evidence: %{message: message, hint: "Check command/event struct definitions"},
            confidence: :high
          }
        }

      message =~ ~r/cannot apply/i ->
        %{
          origin: :test_code_error,
          details: %{
            reason: "Invalid function application",
            evidence: %{
              message: message,
              hint: "Check callback implementations",
              stacktrace_hint: format_stacktrace_hint(stacktrace)
            },
            confidence: :high
          }
        }

      true ->
        classify_generic_exception(error, stacktrace)
    end
  end

  defp classify_generic_exception(exception, stacktrace) do
    test_code? = stacktrace_contains_test_code?(stacktrace)

    if test_code? do
      %{
        origin: :test_code_error,
        details: %{
          reason: "Exception in test code: #{exception.__struct__ |> module_name()}",
          evidence: %{
            message: Exception.message(exception),
            stacktrace_hint: format_stacktrace_hint(stacktrace)
          },
          confidence: :medium
        }
      }
    else
      %{
        origin: :unknown,
        details: %{
          reason: "Exception: #{exception.__struct__ |> module_name()}",
          evidence: %{message: Exception.message(exception)},
          confidence: :low
        }
      }
    end
  end

  # ============================================================================
  # Test Code Detection
  # ============================================================================

  # Patterns that indicate test code modules
  @test_code_patterns [
    ~r/Model$/,
    ~r/Projection$/,
    ~r/Adapter$/,
    # Anchored: a singular command module ends in "Command" (FooCommand). The
    # unanchored ~r/Command/ over-matched any SUT module that merely contained
    # the word (CommandBus, CommandHandler), hiding real SUT bugs behind a
    # "fix your test" verdict. The .Commands. namespace is covered below.
    ~r/Command$/,
    ~r/\.Commands\./,
    ~r/\.Events\./,
    ~r/\.Projections\./,
    ~r/\.Adapters\./,
    ~r/\.Models\./,
    ~r/Test$/
  ]

  defp test_code_module?(nil, _stacktrace), do: false

  defp test_code_module?(module, _stacktrace) do
    module_str = to_string(module)

    Enum.any?(@test_code_patterns, fn pattern ->
      Regex.match?(pattern, module_str)
    end)
  end

  defp stacktrace_contains_test_code?(nil), do: false

  defp stacktrace_contains_test_code?(stacktrace) do
    Enum.any?(stacktrace, fn
      {module, _function, _arity, _location} ->
        test_code_module?(module, nil)

      _ ->
        false
    end)
  end

  defp extract_module_from_function_clause_error(_error, nil), do: nil

  defp extract_module_from_function_clause_error(_error, []) do
    nil
  end

  defp extract_module_from_function_clause_error(_error, [{module, _func, _arity, _loc} | _]) do
    module
  end

  defp extract_module_from_function_clause_error(_error, _other), do: nil

  # ============================================================================
  # Hints and Formatting
  # ============================================================================

  defp suggest_fix_for_undefined_function(module, function, arity) do
    module_str = to_string(module)

    cond do
      module_str =~ ~r/Adapter$/ and function == :execute and arity == 3 ->
        "Implement execute/3 in your adapter module"

      module_str =~ ~r/Adapter$/ and function == :setup and arity == 1 ->
        "Implement setup/1 in your adapter module"

      module_str =~ ~r/Projection$/ and function == :apply and arity == 2 ->
        "Add apply/2 clause for this command/event type"

      module_str =~ ~r/Projection$/ and function == :init and arity == 0 ->
        "Implement init/0 in your projection module"

      module_str =~ ~r/Model$/ and function == :command_sequence_projection and arity == 0 ->
        "Implement command_sequence_projection/0 in your model module"

      true ->
        "Implement #{function}/#{arity} in #{module_name(module)}"
    end
  end

  defp format_stacktrace_hint(nil), do: nil

  defp format_stacktrace_hint([]), do: nil

  defp format_stacktrace_hint([{module, function, arity_or_args, location} | _]) do
    file = Keyword.get(location, :file, "unknown")
    line = Keyword.get(location, :line, 0)
    # Stack frames may carry an args list instead of an integer arity
    # (badarg/undef/function_clause); normalize to a count.
    arity = if is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args
    "#{module_name(module)}.#{function}/#{arity} at #{file}:#{line}"
  end

  defp format_stacktrace_hint(_), do: nil

  defp format_reason(%{message: msg}), do: msg
  defp format_reason(e) when is_exception(e), do: Exception.message(e)
  defp format_reason(other), do: inspect(other, limit: 5)

  # An intentional failure raises PropertyDamage.AssertionFailed (via fail!/2);
  # anything else exception-shaped means the assertion code itself crashed.
  defp assertion_code_crash?(%PropertyDamage.AssertionFailed{}), do: false
  defp assertion_code_crash?({%PropertyDamage.AssertionFailed{}, _stacktrace}), do: false
  defp assertion_code_crash?(exception) when is_exception(exception), do: true
  defp assertion_code_crash?({exception, _stacktrace}) when is_exception(exception), do: true
  defp assertion_code_crash?(_), do: false

  defp get_command_name(%{command: %{__struct__: mod}}), do: module_name(mod)
  defp get_command_name(_), do: "unknown"

  defp module_name(module) when is_atom(module) do
    module |> Module.split() |> List.last()
  rescue
    # Erlang modules (e.g. :erlang) aren't Elixir modules
    ArgumentError -> Atom.to_string(module)
  end

  defp module_name(_), do: "unknown"

  # ============================================================================
  # Public Helpers
  # ============================================================================

  @doc """
  Returns true if the classification indicates a test code error.
  """
  @spec test_code_error?(classification()) :: boolean()
  def test_code_error?(%{origin: :test_code_error}), do: true
  def test_code_error?(_), do: false

  @doc """
  Returns true if the classification indicates a SUT error.
  """
  @spec sut_error?(classification()) :: boolean()
  def sut_error?(%{origin: :sut_error}), do: true
  def sut_error?(_), do: false

  @doc """
  Get a human-readable summary of the classification.
  """
  @spec summary(classification()) :: String.t()
  def summary(%{origin: :sut_error, details: details}) do
    "SUT Bug: #{details.reason}"
  end

  def summary(%{origin: :test_code_error, details: details}) do
    "Test Code Error: #{details.reason}"
  end

  def summary(%{origin: :unknown, details: details}) do
    "Unknown Origin: #{details.reason}"
  end
end
