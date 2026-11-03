defmodule Mix.Tasks.Pd.ExplainFilesTest do
  # async: false because the task prints to stdout and stderr, which the tests
  # capture, and capturing stderr is global. The tests also change the
  # application environment.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.ExplainSupport, as: E

  @config_line "using the command from config :property_damage, :explain_with\n"

  # Sets `explain_with` to a command that creates `sentinel` when it runs.
  defp configure_sentinel(dir) do
    sentinel = Path.join(dir, "sentinel")
    previous = Application.fetch_env(:property_damage, :explain_with)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:property_damage, :explain_with, old)
        :error -> Application.delete_env(:property_damage, :explain_with)
      end
    end)

    Application.put_env(:property_damage, :explain_with, "touch '#{sentinel}'")
    sentinel
  end

  describe "--files" do
    @tag :tmp_dir
    test "writes the two files and runs no command although explain_with is set", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      sentinel = configure_sentinel(dir)

      out = E.exec([page, "--files"])

      assert out.result == :ok
      assert out.stderr == ""
      assert File.exists?(Path.join(page <> ".explain", "bundle.json"))
      assert File.exists?(Path.join(page <> ".explain", "instructions.md"))
      refute File.exists?(sentinel)

      assert String.split(out.stdout, "\n", trim: true) |> length() == 4
      assert out.stdout =~ Path.expand(page <> ".explain/bundle.json")
      assert out.stdout =~ "prompt version: 1"
      assert out.stdout =~ "bundle hash: "
    end

    @tag :tmp_dir
    test "prints the same lines as the no-option mode without a config", %{tmp_dir: dir} do
      plain = E.copy(dir, "page.html", "plain.html")
      flagged = E.copy(dir, "page.html", "flagged.html")

      expected = E.exec([plain]).stdout
      out = E.exec([flagged, "--files"])

      assert out.result == :ok
      assert out.stdout == String.replace(expected, "plain.html", "flagged.html")
    end

    @tag :tmp_dir
    test "on an explained page prints the one line and writes nothing", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      file = E.explanation_file(dir, "valid.json")
      assert E.exec([page, "--apply", file]).result == :ok
      sentinel = configure_sentinel(dir)
      before = E.tree(dir)

      out = E.exec([page, "--files"])

      assert out.result == :ok
      assert out.stderr == ""
      assert out.stdout =~ "#{page} is already explained (bundle "
      assert E.tree(dir) == before
      refute File.exists?(sentinel)
    end

    @tag :tmp_dir
    test "without --files the configured command still runs", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      sentinel = configure_sentinel(dir)

      out = E.exec([page])

      assert out.stderr =~ @config_line
      assert File.exists?(sentinel)
      refute File.exists?(page <> ".explain")
    end
  end

  describe "--files usage errors" do
    @tag :tmp_dir
    test "a mode flag or --with with --files is refused", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      file = E.explanation_file(dir, "valid.json")

      for {args, flag} <- [
            {[page, "--files", "--prompt"], "--prompt"},
            {[page, "--prompt", "--files"], "--prompt"},
            {[page, "--files", "--apply", file], "--apply"},
            {[page, "--files", "--with", "cat"], "--with"}
          ] do
        out = E.exec(args)
        assert out.result == :error, inspect(args)
        assert out.stdout == "", inspect(args)

        assert out.stderr ==
                 "mix pd.explain: --files and #{flag} cannot be used together\n" <>
                   E.usage_line() <> "\n",
               inspect(args)
      end

      refute File.exists?(page <> ".explain")
    end

    @tag :tmp_dir
    test "--attempts and --timeout need --with", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")

      for {extra, option} <- [
            {["--attempts", "2"], "--attempts"},
            {["--timeout", "5s"], "--timeout"}
          ] do
        out = E.exec([page, "--files" | extra])
        assert out.result == :error
        assert out.stdout == ""
        assert out.stderr == "mix pd.explain: #{option} needs --with\n" <> E.usage_line() <> "\n"
      end
    end

    @tag :tmp_dir
    test "--files takes no value", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")

      out = E.exec([page, "--files=yes"])

      assert out.result == :error
      assert out.stdout == ""

      assert out.stderr ==
               "mix pd.explain: --files takes no value, got yes\n" <> E.usage_line() <> "\n"
    end
  end
end
