defmodule PropertyDamage.Log.Filter do
  @moduledoc """
  A tag filter for the log lines of the failure report (DR-054 decision 11).

  A filter hides whole lines from the printed report, by tag. It has two
  parts, each a non-empty list of tags:

    * `only:` shows the lines that carry any listed tag.
    * `except:` hides the lines that carry any listed tag, and wins over
      `only:`.

  A line with no tags is always shown. A retry-cap gap
  (`PropertyDamage.Log.Gap`) is not a line: it is always shown, with its
  counts unchanged. A shown line prints exactly as it does without a filter,
  and hiding a line never moves another line's offset.

  A filter changes what one reader sees and nothing else: it does not change
  which lines a run keeps, the verdict, the shrink or the replay artifact.
  It does not protect a secret either, because a hidden line still sits in
  the report in memory. The code that logs redacts (DR-054 decision 10).

  ## In code

  Give the filter to the run, where it is kept on the report, or to a
  finished report:

      PropertyDamage.run(model: MyModel, targets: targets, log: [only: [:http], except: [:body]])

      PropertyDamage.ExUnit.format_failure(report, log: [except: [:headers]])

  ## `PD_LOG`

  The environment variable `PD_LOG` holds the same filter as text, so one
  report can be read through another filter without a code change:

      PD_LOG="only:http,seed except:body" mix test

  A part is `only:` or `except:` followed by comma-separated tag names. Parts
  are separated by whitespace, each key may appear once, and each part needs
  at least one tag. Spaces around a colon or a comma are tolerated. A value
  that is empty or only whitespace counts as unset.

  When `PD_LOG` is set and non-blank, it replaces the in-code filter, and the
  two are never merged. It applies to every `:terminal`, `:markdown` and
  `:json` report formatted in the process: a test run, a replay call and
  `PropertyDamage.ExUnit.format_failure/2`. It is read only when a report is
  formatted, never during a run. A value that does not parse raises an
  `ArgumentError` that shows the expected syntax. `PD_LOG` is a view filter
  like the option and protects no secret.

  ## What the report prints

  A report formatted with a filter prints it once, as the Failure section's
  `Log filter` field, with its source: `(from the log: option)` or
  `(from PD_LOG)`. A tag the filter lists that no line of the report carries
  is named in a `Log warning` field, which catches a misspelled tag.
  """

  alias PropertyDamage.Log.{Gap, Line}

  @env "PD_LOG"

  @syntax ~s(only:a,b except:c, for example PD_LOG="only:http,seed except:body" ) <>
            "(each part optional, each key at most once, at least one tag per part)"

  @typedoc "A filter as the report keeps it: `only:` and `except:` tag atoms, a part absent when not given."
  @type t :: [only: [atom()], except: [atom()]]

  @typedoc "A filter as applied: tag names as strings, with where it came from."
  @type applied :: %{
          only: [String.t()] | nil,
          except: [String.t()] | nil,
          source: :option | :env
        }

  @doc false
  # The `log:` option's type for `only:` and `except:`: a non-empty list of
  # atoms.
  @spec validate_tags(term()) :: {:ok, [atom()]} | {:error, String.t()}
  def validate_tags([_ | _] = tags) do
    if Enum.all?(tags, &is_atom/1) do
      {:ok, tags}
    else
      {:error, "expected a non-empty list of atoms, got: #{inspect(tags)}"}
    end
  end

  def validate_tags(other),
    do: {:error, "expected a non-empty list of atoms, got: #{inspect(other)}"}

  @doc false
  # The filter a validated `log:` keyword holds: `nil` when it holds neither
  # `only:` nor `except:`.
  @spec from_option(keyword() | nil) :: t() | nil
  def from_option(log) when is_list(log) do
    case Keyword.take(log, [:only, :except]) do
      [] -> nil
      filter -> Enum.sort_by(filter, fn {key, _tags} -> key != :only end)
    end
  end

  def from_option(nil), do: nil

  @doc false
  # Validates the `log:` of `PropertyDamage.ExUnit.format_failure/2`: only
  # `only:` and `except:`, because nothing else can change a finished report.
  @spec validate_format_option!(term()) :: t() | nil
  def validate_format_option!(log) do
    unless is_list(log) and Keyword.keyword?(log) do
      raise ArgumentError,
            "`log:` takes `[only: tags, except: tags]`, got: #{inspect(log)}"
    end

    case Keyword.keys(log) -- [:only, :except] do
      [] ->
        :ok

      other ->
        raise ArgumentError,
              "`log:` of a finished report takes `only:` and `except:`; " <>
                "#{Enum.map_join(Enum.uniq(other), ", ", &"`#{&1}:`")} cannot change a report " <>
                "that is already built"
    end

    log
    |> NimbleOptions.validate!(
      only: [type: {:custom, __MODULE__, :validate_tags, []}],
      except: [type: {:custom, __MODULE__, :validate_tags, []}]
    )
    |> from_option()
  end

  @doc false
  # The filter to apply to `report_filter` and the format options: a set,
  # non-blank `PD_LOG` wins; else a `log:` in the format options replaces the
  # report's own; else the report's own; else none. Never merged. This is the
  # one place that reads the environment.
  @spec resolve(t() | nil, keyword()) :: applied() | nil
  def resolve(report_filter, format_opts) do
    # A `log:` the caller gave is validated whichever filter wins.
    own =
      case Keyword.fetch(format_opts, :log) do
        {:ok, log} -> validate_format_option!(log)
        :error -> report_filter
      end

    env_filter() || applied(own, :option)
  end

  defp env_filter do
    case System.get_env(@env) do
      nil ->
        nil

      text ->
        if String.trim(text) == "", do: nil, else: text |> parse!() |> applied(:env)
    end
  end

  defp applied(nil, _source), do: nil

  defp applied(filter, source) do
    %{
      only: names(filter[:only]),
      except: names(filter[:except]),
      source: source
    }
  end

  defp names(nil), do: nil
  defp names(tags), do: Enum.map(tags, &to_string/1)

  @doc false
  # Parses the text of `PD_LOG` into `[only: names, except: names]` with tag
  # names as strings: the environment creates no atoms. Raises `ArgumentError`
  # with the expected syntax when the text does not parse.
  @spec parse!(String.t()) :: [only: [String.t()], except: [String.t()]]
  def parse!(text) do
    # Spaces around a colon or a comma are tolerated: "only: a, b" reads as
    # "only:a,b". A part and the next are still told apart by whitespace.
    text
    |> String.replace(~r/\s*([:,])\s*/, "\\1")
    |> String.split()
    |> Enum.reduce([], &parse_part!(&1, &2, text))
    |> case do
      [] -> fail!(text, "it holds no part")
      parts -> Enum.sort_by(parts, fn {key, _names} -> key != :only end)
    end
  end

  defp parse_part!(part, parsed, text) do
    case String.split(part, ":", parts: 2) do
      [key, names] when key in ["only", "except"] ->
        key = String.to_existing_atom(key)
        if Keyword.has_key?(parsed, key), do: fail!(text, "`#{key}:` appears twice")
        [{key, tag_names!(names, key, text)} | parsed]

      [key, _names] ->
        fail!(text, "`#{key}:` is not a part, parts are `only:` and `except:`")

      [other] ->
        fail!(text, "`#{other}` is not a part, a part starts with `only:` or `except:`")
    end
  end

  defp tag_names!(names, key, text) do
    tags = String.split(names, ",")

    if names == "" or "" in tags or Enum.any?(tags, &String.contains?(&1, ":")) do
      fail!(text, "`#{key}:` needs comma-separated tag names")
    end

    tags
  end

  defp fail!(text, reason) do
    raise ArgumentError, "#{@env}=#{inspect(text)} does not parse: #{reason}. Expected #{@syntax}"
  end

  @doc false
  # Whether a log line prints under `filter`: it has no tags, or (the filter
  # has no `only:` or it carries a listed `only:` tag) and (the filter has no
  # `except:` or it carries no listed `except:` tag). A gap always prints.
  @spec shown?(Line.t() | Gap.t(), applied() | nil) :: boolean()
  def shown?(_line, nil), do: true
  def shown?(%Gap{}, _filter), do: true
  def shown?(%Line{tags: []}, _filter), do: true

  def shown?(%Line{tags: tags}, %{only: only, except: except}) do
    names = Enum.map(tags, &to_string/1)

    (only == nil or Enum.any?(names, &(&1 in only))) and
      (except == nil or not Enum.any?(names, &(&1 in except)))
  end

  @doc false
  # The listed tags no line carries, in the order given, without duplicates.
  # `known` is the set of tag names the report's lines carry.
  @spec unknown(applied() | nil, MapSet.t(String.t())) :: [String.t()]
  def unknown(nil, _known), do: []

  def unknown(%{only: only, except: except}, known) do
    ((only || []) ++ (except || []))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(known, &1))
  end

  @doc false
  # The tag names a list of lines and gaps carries.
  @spec tag_names([Line.t() | Gap.t()]) :: [String.t()]
  def tag_names(lines), do: for(%Line{tags: tags} <- lines, tag <- tags, do: to_string(tag))

  @doc false
  # The text of the report's `Log filter` field.
  @spec describe(applied()) :: String.t()
  def describe(%{only: only, except: except, source: source}) do
    parts =
      [only: only, except: except]
      |> Enum.reject(fn {_key, tags} -> tags == nil end)
      |> Enum.map_join(" ", fn {key, tags} -> "#{key}: [#{tag_list(tags)}]" end)

    parts <> " " <> source_text(source)
  end

  @doc false
  # The text of the report's `Log warning` field.
  @spec describe_unknown([String.t()]) :: String.t()
  def describe_unknown([tag]), do: "no line carries the tag :#{tag}"
  def describe_unknown(tags), do: "no line carries the tags #{tag_list(tags)}"

  defp tag_list(tags), do: Enum.map_join(tags, ", ", &":#{&1}")

  defp source_text(:option), do: "(from the log: option)"
  defp source_text(:env), do: "(from #{@env})"
end
