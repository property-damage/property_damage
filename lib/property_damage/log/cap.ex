defmodule PropertyDamage.Log.Cap do
  @moduledoc false
  # The retry cap on one step's log lines (DR-054 decision 13), as a value.
  #
  # A step keeps the lines of its first execution and of the `keep` most
  # recent executions after it. A line of an execution that arrives when the
  # recent ones are full pushes the oldest of them out: its lines are dropped
  # and counted in a `PropertyDamage.Log.Gap`. Executions are kept or dropped
  # whole; a line is never cut.
  #
  # An execution is keyed by the phase that ran it and its attempt number:
  # the command's own settle attempts (`:command`, 1..n), then its stutter
  # retries (`:stutter`, from 2). The two numberings overlap, so the phase is
  # part of the key, and every `:command` key sorts before every `:stutter`
  # key. The execution of key `{:command, 1}` is the first one and is never
  # dropped. A step's executions are known from the lines they write: an
  # execution that writes none is not counted.
  #
  # Lines held at any moment belong to at most `keep + 1` executions.
  #
  # `dropped` holds the keys of the executions the gap counts, so each
  # dropped execution counts once: when a newer one pushes it out, or when it
  # writes its first line after it can no longer be kept. A cap built from a
  # returned list starts with none, because the list does not say which
  # executions its gap counts.

  alias PropertyDamage.Log.{Gap, Line}

  @default_keep_attempts 3
  @first {0, 1}

  defstruct keep: @default_keep_attempts,
            phase: :command,
            first: [],
            tail: [],
            gap: nil,
            dropped: MapSet.new()

  # `first` and the lines of each `tail` entry are newest first; `tail` is
  # newest execution first.
  @type t :: %__MODULE__{
          keep: pos_integer(),
          phase: :command | :stutter,
          first: [Line.t()],
          tail: [{{0 | 1, pos_integer()}, [Line.t()]}],
          gap: Gap.t() | nil,
          dropped: MapSet.t({0 | 1, pos_integer()})
        }

  @doc "How many of a step's last executions are kept unless `log: [keep_attempts: n]` says otherwise."
  @spec default_keep_attempts() :: pos_integer()
  def default_keep_attempts, do: @default_keep_attempts

  @doc """
  A cap that keeps `keep` recent executions and records new lines under
  `phase`, starting from `lines`, the list a cap returned earlier (a gap
  included), or `[]`. A line of `lines` with attempt 1 counts as the first
  execution's, whatever its place in the list; the others are grouped by
  attempt number as `:command` executions.
  """
  @spec new(pos_integer(), :command | :stutter, [Line.t() | Gap.t()]) :: t()
  def new(keep, phase \\ :command, lines \\ []) do
    {gaps, lines} = Enum.split_with(lines, &is_struct(&1, Gap))
    {first, rest} = Enum.split_with(lines, &(&1.attempt == 1))

    tail =
      rest
      |> Enum.group_by(& &1.attempt)
      |> Enum.sort(:desc)
      |> Enum.map(fn {attempt, group} -> {{0, attempt}, Enum.reverse(group)} end)

    %__MODULE__{
      keep: keep,
      phase: phase,
      first: Enum.reverse(first),
      tail: tail,
      gap: List.first(gaps)
    }
  end

  @doc "Records `line` under the execution that wrote it, dropping an execution if the tail is full."
  @spec add(t(), Line.t()) :: t()
  def add(%__MODULE__{} = cap, %Line{} = line) do
    key = {rank(cap.phase), line.attempt}

    cond do
      key == @first -> %{cap | first: [line | cap.first]}
      List.keymember?(cap.tail, key, 0) -> append(cap, key, line)
      newest?(cap, key) -> push(cap, key, line)
      length(cap.tail) < cap.keep -> insert(cap, key, line)
      true -> omit(cap, key, line)
    end
  end

  @doc "The lines to keep, in order: the first execution's, the gap if any, the recent executions'."
  @spec lines(t()) :: [Line.t() | Gap.t()]
  def lines(%__MODULE__{} = cap) do
    recent =
      cap.tail |> Enum.reverse() |> Enum.flat_map(fn {_key, lines} -> Enum.reverse(lines) end)

    Enum.reverse(cap.first) ++ List.wrap(cap.gap) ++ recent
  end

  @doc "How many executions' lines the cap holds right now."
  @spec attempts_held(t()) :: non_neg_integer()
  def attempts_held(%__MODULE__{} = cap) do
    length(cap.tail) + if(cap.first == [], do: 0, else: 1)
  end

  defp rank(:command), do: 0
  defp rank(:stutter), do: 1

  defp newest?(%__MODULE__{tail: []}, _key), do: true
  defp newest?(%__MODULE__{tail: [{newest, _lines} | _older]}, key), do: key > newest

  defp append(cap, key, line) do
    tail =
      Enum.map(cap.tail, fn
        {^key, lines} -> {key, [line | lines]}
        other -> other
      end)

    %{cap | tail: tail}
  end

  defp push(cap, key, line) do
    tail = [{key, [line]} | cap.tail]

    if length(tail) > cap.keep do
      {dropped_key, dropped} = List.last(tail)

      %{
        cap
        | tail: Enum.drop(tail, -1),
          gap: add_to_gap(cap.gap, 1, dropped),
          dropped: MapSet.put(cap.dropped, dropped_key)
      }
    else
      %{cap | tail: tail}
    end
  end

  # A line of an execution older than the newest kept one, while the tail
  # still has room: nothing was dropped yet, so the execution takes its place.
  defp insert(cap, key, line) do
    %{cap | tail: Enum.sort_by([{key, [line]} | cap.tail], &elem(&1, 0), :desc)}
  end

  # A line of an execution that is no longer kept (or never was). The
  # execution counts as an attempt unless the gap already counts it.
  defp omit(cap, key, line) do
    attempts = if MapSet.member?(cap.dropped, key), do: 0, else: 1

    %{
      cap
      | gap: add_to_gap(cap.gap, attempts, [line]),
        dropped: MapSet.put(cap.dropped, key)
    }
  end

  defp add_to_gap(gap, attempts, lines) do
    earliest = lines |> Enum.map(& &1.timestamp) |> Enum.min()

    case gap do
      nil ->
        %Gap{attempts: attempts, lines: length(lines), timestamp: earliest}

      %Gap{} ->
        %Gap{
          attempts: gap.attempts + attempts,
          lines: gap.lines + length(lines),
          timestamp: min(gap.timestamp, earliest)
        }
    end
  end
end
