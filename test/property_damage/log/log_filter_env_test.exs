defmodule PropertyDamage.Log.LogFilterEnvTest do
  # `PD_LOG` (DR-054 decision 11) holds a tag filter as text, `only:a,b
  # except:c`. When set and non-blank it replaces the in-code filter, never
  # merges with it, and is read only when a report is formatted, so a run is
  # the same with and without it. This module sets the environment variable in
  # the test process with `System.put_env/2` and restores it in `on_exit`, so it
  # is `async: false`.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.TmpPath

  @syntax "only:http,seed except:body"

  setup do
    F.compile!()
    previous = System.get_env("PD_LOG")
    System.delete_env("PD_LOG")

    on_exit(fn ->
      if previous, do: System.put_env("PD_LOG", previous), else: System.delete_env("PD_LOG")
    end)

    dir = TmpPath.unique("pd_log_env")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp lines_of(text, marker), do: for(l <- String.split(text, "\n"), l =~ marker, do: l)

  describe "the value" do
    test "replaces the in-code filter and is never merged with it" do
      report = F.filter_report!(log: [only: [:seed], except: [:body]])
      assert F.step_zero_shown(F.plain(report)) == ["plain line", "SEED-HIDDEN"]

      System.put_env("PD_LOG", "only:http")
      text = F.plain(report)

      # `except: [:body]` of the code is gone, and `only: [:seed]` too.
      assert F.step_zero_shown(text) == ["plain line", "GET /a", "accept: json", "BODY-HIDDEN"]
      assert [line] = lines_of(text, "Log filter")
      assert line =~ "PD_LOG"
      assert line =~ "only: [:http]"
      refute line =~ "log:"
      refute line =~ ":seed"
    end

    test "filters a report that has no in-code filter, in terminal and markdown" do
      report = F.filter_report!()
      System.put_env("PD_LOG", "only:headers except:seed")

      for text <- [F.plain(report), F.markdown(report)] do
        assert [line] = lines_of(text, "Log filter")
        assert line =~ "only: [:headers]"
        assert line =~ "except: [:seed]"
        assert line =~ "PD_LOG"
      end

      assert F.step_zero_shown(F.plain(report)) == ["plain line", "accept: json"]
    end

    test "applies to format_failure/1 and to /2, which it also replaces" do
      report = F.filter_report!(log: [only: [:seed]])
      System.put_env("PD_LOG", "only:headers")

      for text <- [
            PropertyDamage.ExUnit.format_failure(report),
            PropertyDamage.ExUnit.format_failure(report, log: [only: [:seed]])
          ] do
        text = F.strip_ansi(text)
        assert F.step_zero_shown(text) == ["plain line", "accept: json"]
        assert [line] = lines_of(text, "Log filter")
        assert line =~ "PD_LOG"
      end
    end

    test "a tag that no line carries gets the unknown-tag warning" do
      report = F.filter_report!()
      System.put_env("PD_LOG", "only:http,sed except:nobody")

      for text <- [F.plain(report), F.markdown(report)] do
        assert [line] = lines_of(text, "Log warning")
        assert line =~ ":sed, :nobody"
      end
    end

    test "an empty or blank value counts as unset" do
      report = F.filter_report!(log: [only: [:headers]])

      for blank <- ["", "   ", "\t "] do
        System.put_env("PD_LOG", blank)
        text = F.plain(report)

        # The in-code filter applies and the source is the option.
        assert F.step_zero_shown(text) == ["plain line", "accept: json"]
        assert [line] = lines_of(text, "Log filter")
        assert line =~ "log:"
      end
    end

    test "spaces around the parts, the commas and the colons are tolerated" do
      report = F.filter_report!()

      for value <- [" only: headers , seed   except : body ", "only:headers, seed except:body"] do
        System.put_env("PD_LOG", value)
        text = F.plain(report)
        assert F.step_zero_shown(text) == ["plain line", "accept: json", "SEED-HIDDEN"]
        assert [line] = lines_of(text, "Log filter")
        assert line =~ "only: [:headers, :seed]"
      end
    end

    test "either part may be absent" do
      report = F.filter_report!()

      System.put_env("PD_LOG", "except:http")
      assert F.step_zero_shown(F.plain(report)) == ["plain line", "SEED-HIDDEN"]

      System.put_env("PD_LOG", "only:seed")
      assert F.step_zero_shown(F.plain(report)) == ["plain line", "SEED-HIDDEN"]
    end
  end

  describe "a value that does not parse" do
    test "the run completes and returns its report; formatting raises with the syntax" do
      System.put_env("PD_LOG", "only")

      report = F.filter_report!()
      assert %PropertyDamage.FailureReport{} = report

      for format <- [:terminal, :markdown, :json] do
        error = assert_raise ArgumentError, fn -> Formatter.format(report, format, []) end
        message = Exception.message(error)
        assert message =~ ~s("only")
        assert message =~ @syntax
      end

      assert_raise ArgumentError, fn -> PropertyDamage.ExUnit.format_failure(report) end
    end

    test "each malformed shape raises and quotes the value" do
      report = F.filter_report!()

      for bad <- [
            "bogus:x",
            "only:",
            "only:a only:b",
            "except: only:a",
            "only:a,,b",
            "only:a,",
            "plain",
            "only:a b"
          ] do
        System.put_env("PD_LOG", bad)
        error = assert_raise ArgumentError, fn -> F.plain(report) end
        assert Exception.message(error) =~ inspect(bad)
        assert Exception.message(error) =~ @syntax
      end
    end

    test ":compact ignores PD_LOG, even an invalid one" do
      report = F.filter_report!()
      expected = Formatter.format(report, :compact)

      for value <- ["only:http", "nonsense"] do
        System.put_env("PD_LOG", value)
        assert Formatter.format(report, :compact) == expected
      end
    end
  end

  describe "invariance" do
    # One run: shrinking on, a replay directory; its observable result.
    defp observed(dir, pd_log) do
      if pd_log, do: System.put_env("PD_LOG", pd_log), else: System.delete_env("PD_LOG")

      targets = [F.target("alice", %{quiet: true, script: F.filter_script()})]

      report =
        F.report!(F.CapModel, targets,
          shrink: true,
          replay_dir: dir,
          max_commands: 12,
          max_runs: 20,
          seed: 7,
          log: [keep_attempts: 2]
        )

      files = for f <- Path.wildcard(Path.join(dir, "**/*")), File.regular?(f), do: f

      artifact =
        for file <- Enum.sort(files),
            into: %{},
            do: {Path.relative_to(file, dir), File.read!(file)}

      {report, artifact}
    end

    test "the verdict, shrink and replay artifact are the same with and without PD_LOG", %{
      dir: dir
    } do
      {plain, plain_files} = observed(Path.join(dir, "without"), nil)
      {set, set_files} = observed(Path.join(dir, "with"), "only:headers except:seed")

      assert plain.kind == set.kind
      assert plain.failure_reason == set.failure_reason
      assert plain.failed_at_index == set.failed_at_index
      assert plain.shrink_iterations == set.shrink_iterations
      assert plain.trace.plan == set.trace.plan
      assert plain.original_sequence == set.original_sequence
      assert plain.replay_status == :written and set.replay_status == :written
      assert map_size(plain_files) > 0, "control: an artifact was written"

      assert plain_files == set_files

      # The variable still filters what the set run prints.
      assert F.plain(set) =~ "(from PD_LOG)"
    end
  end
end
