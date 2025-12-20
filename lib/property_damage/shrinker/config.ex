defmodule PropertyDamage.Shrinker.Config do
  @moduledoc """
  Configuration for the shrinking process.

  Controls shrinking behavior including thresholds, limits, and strategies.

  ## Fields

  - `:granularity_threshold` - Minimum sequence length before switching from
    hierarchical to linear shrinking. Below this threshold, linear shrinking
    is more efficient. Default: 8

  - `:max_iterations` - Maximum number of shrink attempts before giving up.
    Prevents infinite loops in edge cases. Default: 1000

  - `:max_time_ms` - Maximum time in milliseconds for shrinking. Useful for
    large failing sequences. Default: 30000 (30 seconds)

  - `:shrink_arguments` - Whether to attempt argument shrinking after sequence
    shrinking. Can make failures more minimal but takes longer. Default: true

  ## Example

      config = %Config{
        granularity_threshold: 4,
        max_iterations: 500,
        max_time_ms: 10_000,
        shrink_arguments: false
      }
  """

  @type t :: %__MODULE__{
          granularity_threshold: pos_integer(),
          max_iterations: pos_integer(),
          max_time_ms: pos_integer(),
          shrink_arguments: boolean()
        }

  defstruct granularity_threshold: 8,
            max_iterations: 1000,
            max_time_ms: 30_000,
            shrink_arguments: true

  @doc """
  Create a new config with defaults.

  ## Examples

      iex> config = PropertyDamage.Shrinker.Config.new()
      iex> config.granularity_threshold
      8
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Create a new config with custom options.

  ## Options

  See module documentation for available options.

  ## Examples

      iex> config = PropertyDamage.Shrinker.Config.new(max_iterations: 100)
      iex> config.max_iterations
      100
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end
end
