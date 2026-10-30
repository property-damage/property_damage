defmodule PropertyDamage.FailureReport.Explanation do
  @moduledoc """
  Reads the bundle of a failure page, checks an explanation of the failure
  against it, and embeds the explanation in the page.

  An explanation is a JSON object a person or a language model wrote about one
  failure page. It makes claims and cites the page by id. This module accepts
  an explanation only if its shape is right and every id it cites exists in the
  page's bundle, so a reader can follow each claim back to the page. The module
  prints nothing and calls no model; `mix pd.explain` does the printing and the
  file writes.

  ## The page

  A failure page holds one `pd-bundle` script tag (see
  `PropertyDamage.FailureReport.Bundle`). The bundle bytes are the bytes between
  the tag and its closing `</script>`, unchanged. The bundle hash is the
  lowercase hex SHA-256 of those bytes. An explanation lives in a
  `pd-explanation` script tag that `embed/3` writes right after the bundle tag.

  ## The prompt

  `instructions/0` is the text that tells a model how to write an explanation.
  `prompt_version/0` names that text. Change the text only together with the
  version, because a page records the version its explanation was written for.

  ## The explanation

  An explanation has the keys `summary`, `hypotheses` and `talking_points`, and
  may carry the `bundle_hash` of the page it was written for.

    * `summary` and `talking_points` are non-empty lists of `{text, cites}`
      objects. `text` is a non-empty string and `cites` a non-empty list of ids.
    * `hypotheses` is a non-empty list of objects with `rank`, `likelihood`
      (`likely`, `possible` or `unlikely`), `claim`, `evidence` (a non-empty list
      of ids) and `next_steps` (a non-empty list of non-empty strings). The ranks
      run 1 to n in order, and a hypothesis is never more likely than the one
      ranked above it.

  An id resolves when the bundle lists it, or when it has the form
  `source:<Module>:<from>-<to>` and the bundle holds the source of `<Module>`
  with at least `<to>` lines. A hypothesis may not cite the context item of a
  missing description as evidence.
  """

  @prompt_version 1
  @supported_formats [1]

  @instructions_path Path.expand("../../../priv/explain/instructions.md", __DIR__)
  @external_resource @instructions_path
  @instructions File.read!(@instructions_path)

  @bundle_open ~s(<script type="application/json" id="pd-bundle">)
  @explanation_open ~s(<script type="application/json" id="pd-explanation">)
  @script_close "</script>"

  @likelihoods %{"likely" => 3, "possible" => 2, "unlikely" => 1}

  @entry_specs %{
    "summary" => [{"text", :text}, {"cites", :strings}],
    "talking_points" => [{"text", :text}, {"cites", :strings}],
    "hypotheses" => [
      {"rank", :rank},
      {"likelihood", :likelihood},
      {"claim", :text},
      {"evidence", :strings},
      {"next_steps", :steps}
    ]
  }
  @parts ["summary", "hypotheses", "talking_points"]

  @typedoc "A bundle read from a page: its bytes, their hash, and the decoded map."
  @type bundle :: %{bytes: binary(), hash: String.t(), data: map()}

  @doc "The version of the instructions. It goes up whenever the text changes."
  @spec prompt_version() :: pos_integer()
  def prompt_version, do: @prompt_version

  @doc "The instructions that tell a model how to write an explanation."
  @spec instructions() :: binary()
  def instructions, do: @instructions

  @doc "The bundle formats this version reads."
  @spec supported_formats() :: [pos_integer()]
  def supported_formats, do: @supported_formats

  @doc """
  Reads the bundle out of the HTML of a failure page.

  `page` names the page in error lines. Returns `{:error, lines}` when the page
  has no bundle, more than one, a bundle that is not a JSON object, or a bundle
  format this version does not read.
  """
  @spec read_bundle(binary(), String.t()) :: {:ok, bundle()} | {:error, [String.t()]}
  def read_bundle(html, page) do
    with {:ok, bytes} <- cut_bundle(html, page),
         {:ok, data} <- decode_bundle(bytes, page),
         :ok <- check_format(data, page) do
      {:ok, %{bytes: bytes, hash: sha256(bytes), data: data}}
    end
  end

  @doc "The text a model receives: the instructions, a newline, the bundle bytes, a newline."
  @spec prompt(bundle()) :: binary()
  def prompt(%{bytes: bytes}), do: @instructions <> "\n" <> bytes <> "\n"

  @doc """
  Whether the page holds an explanation of this bundle for the current prompt
  version.

  A tag that does not decode to an object, or that names another hash or
  version, does not count.
  """
  @spec explained?(binary(), bundle()) :: boolean()
  def explained?(html, %{hash: hash}) do
    html
    |> explanation_tags()
    |> Enum.any?(fn {_start, _stop, json} ->
      match?(
        {:ok, %{"bundle_hash" => ^hash, "prompt_version" => @prompt_version}},
        Jason.decode(json)
      )
    end)
  end

  @doc """
  Checks that every earlier `pd-explanation` tag of the page can be removed.

  A tag is malformed when no `</script>` follows its opener, or when another
  script opener comes before that `</script>`. `embed/3` cannot tell where such
  a tag ends, so the page needs a hand edit first.
  """
  @spec check_earlier(binary(), String.t()) :: :ok | {:error, [String.t()]}
  def check_earlier(html, page) do
    if Enum.any?(:binary.matches(html, @explanation_open), &malformed?(html, &1)) do
      {:error,
       [
         "#{page}: an earlier explanation in this page is malformed; " <>
           "remove its pd-explanation tag by hand"
       ]}
    else
      :ok
    end
  end

  @doc """
  Checks the text of an explanation against the page's bundle.

  Returns the explanation (the three parts, without a `bundle_hash`) or every
  problem found, one line each: the schema lines, then the hash line, then the
  citation lines in order of first appearance.
  """
  @spec validate(binary(), bundle()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(text, bundle) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> validate_object(map, bundle)
      {:ok, other} -> {:error, [not_an_object("it is #{describe_value(other)}")]}
      {:error, error} -> {:error, [not_an_object(Exception.message(error))]}
    end
  end

  @doc """
  Writes the explanation into the page and returns the new page.

  Every earlier `pd-explanation` tag is removed, and the new tag goes right
  after the closing `</script>` of the bundle tag. No other byte changes. The
  JSON is escaped so that text holding `</script>` cannot end the tag.
  """
  @spec embed(binary(), bundle(), map()) :: binary()
  def embed(html, %{hash: hash}, explanation) do
    json =
      Jason.encode!(
        %{
          "format" => 1,
          "bundle_hash" => hash,
          "prompt_version" => @prompt_version,
          "explanation" => explanation
        },
        escape: :html_safe
      )

    {head, rest} = split_once(remove_explanations(html), @bundle_open)
    {bytes, tail} = split_once(rest, @script_close)

    head <>
      @bundle_open <>
      bytes <>
      @script_close <>
      @explanation_open <>
      json <>
      @script_close <> tail
  end

  # ===========================================================================
  # The page
  # ===========================================================================

  defp cut_bundle(html, page) do
    case :binary.matches(html, @bundle_open) do
      [] ->
        {:error,
         [
           "#{page}: no bundle in this page " <>
             "(it was written by a version that did not embed one)"
         ]}

      [_one] ->
        {_head, rest} = split_once(html, @bundle_open)

        case String.split(rest, @script_close, parts: 2) do
          [bytes, _tail] -> {:ok, bytes}
          [_unclosed] -> {:error, ["#{page}: the bundle in this page is not valid JSON"]}
        end

      _several ->
        {:error, ["#{page}: more than one bundle in this page"]}
    end
  end

  defp decode_bundle(bytes, page) do
    case Jason.decode(bytes) do
      {:ok, %{} = data} -> {:ok, data}
      _other -> {:error, ["#{page}: the bundle in this page is not valid JSON"]}
    end
  end

  defp check_format(%{"format" => format}, _page) when format in @supported_formats, do: :ok

  defp check_format(data, page) do
    shown =
      case Map.get(data, "format") do
        nil -> "missing"
        format when is_integer(format) -> to_string(format)
        format when is_binary(format) -> show(format)
        other -> inspect(other)
      end

    {:error,
     [
       "#{page}: bundle format #{shown} is not supported; " <>
         "this version reads formats: #{Enum.join(@supported_formats, ", ")}"
     ]}
  end

  # A value from the input goes into an error line as is, unless it holds a
  # control character that could break the line or forge another one; then it
  # prints quoted and escaped.
  defp show(text) when is_binary(text) do
    if String.match?(text, ~r/[\x00-\x1f\x7f]/), do: inspect(text), else: text
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # Every explanation tag as {start, stop, json}: the byte range of the whole
  # tag in the page and the text between its tags. A tag with no closing tag
  # ends the scan.
  defp explanation_tags(html) do
    html
    |> :binary.matches(@explanation_open)
    |> Enum.flat_map(fn {start, length} ->
      body_start = start + length
      rest = binary_part(html, body_start, byte_size(html) - body_start)

      case :binary.match(rest, @script_close) do
        {close, close_length} ->
          [{start, body_start + close + close_length, binary_part(rest, 0, close)}]

        :nomatch ->
          []
      end
    end)
  end

  defp malformed?(html, {start, length}) do
    body_start = start + length
    rest = binary_part(html, body_start, byte_size(html) - body_start)

    case :binary.match(rest, @script_close) do
      {close, _length} -> :binary.match(binary_part(rest, 0, close), "<script") != :nomatch
      :nomatch -> true
    end
  end

  defp remove_explanations(html) do
    {kept, offset} =
      html
      |> explanation_tags()
      |> Enum.reduce({[], 0}, fn {start, stop, _json}, {kept, offset} ->
        {[binary_part(html, offset, start - offset) | kept], stop}
      end)

    [binary_part(html, offset, byte_size(html) - offset) | kept]
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp split_once(binary, pattern) do
    [head, tail] = :binary.split(binary, pattern)
    {head, tail}
  end

  # ===========================================================================
  # The explanation
  # ===========================================================================

  defp validate_object(map, bundle) do
    lines =
      schema_lines(map) ++ hash_lines(map, bundle.hash) ++ citation_lines(map, index(bundle.data))

    case lines do
      [] -> {:ok, Map.take(map, @parts)}
      lines -> {:error, lines}
    end
  end

  defp not_an_object(reason), do: "schema: not a JSON object (#{reason})"

  defp describe_value(list) when is_list(list), do: "a list"
  defp describe_value(text) when is_binary(text), do: "a string"
  defp describe_value(number) when is_number(number), do: "a number"
  defp describe_value(nil), do: "null"
  defp describe_value(bool) when is_boolean(bool), do: "a boolean"

  # --- schema ----------------------------------------------------------------

  defp schema_lines(map) do
    unknown =
      for key <- Map.keys(map),
          key not in ["bundle_hash" | @parts],
          do: "schema: unknown key #{show(key)}"

    unknown ++
      Enum.flat_map(@parts, &part_lines(map, &1)) ++ hash_shape_lines(map) ++ order_lines(map)
  end

  defp part_lines(map, part) do
    case Map.fetch(map, part) do
      :error ->
        ["schema: #{part}: missing"]

      {:ok, [_ | _] = entries} ->
        spec = Map.fetch!(@entry_specs, part)

        entries
        |> Enum.with_index()
        |> Enum.flat_map(fn {entry, index} -> entry_lines("#{part}[#{index}]", entry, spec) end)

      {:ok, _other} ->
        ["schema: #{part}: must be a non-empty list of objects"]
    end
  end

  defp entry_lines(path, %{} = entry, spec) do
    known = Enum.map(spec, &elem(&1, 0))

    unknown =
      for key <- Map.keys(entry),
          key not in known,
          do: "schema: #{path}: unknown key #{show(key)}"

    unknown ++
      Enum.flat_map(spec, fn {key, shape} ->
        case Map.fetch(entry, key) do
          :error ->
            ["schema: #{path}.#{key}: missing"]

          {:ok, value} ->
            if valid?(shape, value),
              do: [],
              else: ["schema: #{path}.#{key}: must be #{describe(shape)}"]
        end
      end)
  end

  defp entry_lines(path, _not_a_map, _spec), do: ["schema: #{path}: must be an object"]

  defp hash_shape_lines(%{"bundle_hash" => hash}) when not is_binary(hash),
    do: ["schema: bundle_hash: must be a string"]

  defp hash_shape_lines(_map), do: []

  defp valid?(:text, value), do: is_binary(value) and value != ""
  defp valid?(:strings, value), do: strings?(value)
  defp valid?(:steps, value), do: strings?(value) and Enum.all?(value, &(&1 != ""))
  defp valid?(:rank, value), do: is_integer(value)
  defp valid?(:likelihood, value), do: is_map_key(@likelihoods, value)

  defp describe(:text), do: "a non-empty string"
  defp describe(:strings), do: "a non-empty list of strings"
  defp describe(:steps), do: "a non-empty list of non-empty strings"
  defp describe(:rank), do: "an integer"
  defp describe(:likelihood), do: "likely, possible or unlikely"

  defp strings?([_ | _] = list), do: Enum.all?(list, &is_binary/1)
  defp strings?(_other), do: false

  # Rank and likelihood order need the whole hypotheses list, so they run after
  # the per-entry checks and only on entries those checks left readable.
  defp order_lines(%{"hypotheses" => [_ | _] = hypotheses}) do
    rank_lines(hypotheses) ++ likelihood_lines(hypotheses)
  end

  defp order_lines(_map), do: []

  defp rank_lines(hypotheses) do
    ranks = Enum.map(hypotheses, &(is_map(&1) && Map.get(&1, "rank")))

    if Enum.all?(ranks, &is_integer/1) and ranks != Enum.to_list(1..length(ranks)) do
      ["schema: hypotheses: ranks must run 1 to #{length(ranks)} in order, each once"]
    else
      []
    end
  end

  defp likelihood_lines(hypotheses) do
    words = Enum.map(hypotheses, &(is_map(&1) && Map.get(&1, "likelihood")))

    words
    |> Enum.with_index()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{above, _}, {below, index}] ->
      if is_map_key(@likelihoods, above) and is_map_key(@likelihoods, below) and
           @likelihoods[below] > @likelihoods[above] do
        [
          "schema: hypotheses[#{index}].likelihood: #{below} is higher than #{above} in hypotheses[#{index - 1}]"
        ]
      else
        []
      end
    end)
  end

  # --- hash ------------------------------------------------------------------

  defp hash_lines(%{"bundle_hash" => given}, hash) when is_binary(given) and given != hash,
    do: ["bundle hash mismatch: explanation #{show(given)}, page #{hash}"]

  defp hash_lines(_map, _hash), do: []

  # --- citations -------------------------------------------------------------

  defp index(data) do
    modules = list_of_maps(data["modules"])
    context = list_of_maps(data["context"])

    %{
      ids: for(id <- listed(data["ids"]), is_binary(id), into: MapSet.new(), do: id),
      lines:
        for(
          %{"module" => name, "source" => source, "lines" => lines} <- modules,
          is_binary(name) and is_binary(source) and is_integer(lines),
          into: %{},
          do: {name, lines}
        ),
      gaps:
        for(
          %{"id" => id, "missing" => missing} <- context,
          is_binary(id) and missing not in [nil, false],
          into: MapSet.new(),
          do: id
        )
    }
  end

  defp listed(list) when is_list(list), do: list
  defp listed(_other), do: []

  defp list_of_maps(value), do: for(%{} = item <- listed(value), do: item)

  # The cited ids in order of first appearance, each with where it was cited.
  # A part whose shape is wrong is skipped here; the schema lines report it.
  defp citation_lines(map, index) do
    cited =
      cited(map, "summary", "cites", :cite) ++
        cited(map, "hypotheses", "evidence", :evidence) ++
        cited(map, "talking_points", "cites", :cite)

    {lines, _seen} =
      Enum.reduce(cited, {[], MapSet.new()}, fn {id, kind}, {lines, seen} ->
        with false <- MapSet.member?(seen, id),
             {:error, line} <- check_id(id, kind, index) do
          {[line | lines], MapSet.put(seen, id)}
        else
          _resolved_or_seen -> {lines, seen}
        end
      end)

    Enum.reverse(lines)
  end

  defp cited(map, part, key, kind) do
    for %{} = entry <- listed(map[part]),
        strings?(entry[key]),
        id <- entry[key],
        do: {id, kind}
  end

  defp check_id(id, :evidence, %{gaps: gaps} = index) do
    if MapSet.member?(gaps, id),
      do: {:error, "#{show(id)}: a missing description is not evidence"},
      else: check_id(id, :cite, index)
  end

  defp check_id(id, :cite, index) do
    if MapSet.member?(index.ids, id), do: :ok, else: check_range(id, index)
  end

  defp check_range(id, index) do
    with [_all, module, from, to] <-
           Regex.run(~r/\Asource:(.+):([0-9]+)-([0-9]+)\z/s, id),
         {:ok, lines} <- Map.fetch(index.lines, module) do
      {first, last} = {String.to_integer(from), String.to_integer(to)}

      if 1 <= first and first <= last and last <= lines,
        do: :ok,
        else:
          {:error, "source:#{show(module)}:#{from}-#{to}: lines #{from}-#{to} outside 1-#{lines}"}
    else
      _not_a_known_range -> {:error, "#{show(id)}: not in this page"}
    end
  end
end
