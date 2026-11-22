defmodule PropertyDamage.Next.Test.Surface do
  @moduledoc false
  # Calls into the shrinker's public surface and reads its new struct fields
  # without naming them at compile time, so the suite keeps compiling while
  # that surface is being built. A missing function or field fails the test
  # that uses it, at run time.

  @doc "`PropertyDamage.Next.Steering.walk/3`."
  def walk(stream_data, seed, path),
    do: Function.capture(steering(), :walk, 3).(stream_data, seed, path)

  @doc "`PropertyDamage.Next.Steering.child_count/3`."
  def child_count(stream_data, seed, path),
    do: Function.capture(steering(), :child_count, 3).(stream_data, seed, path)

  @doc "A field of a struct or map, raising `KeyError` if it is missing."
  def field(term, key), do: Map.fetch!(term, key)

  @doc "The exception raised for a dependent StreamData generator in raise mode."
  def dependent_error, do: Module.concat(PropertyDamage.Next, DependentStreamDataError)

  defp steering, do: Module.concat(PropertyDamage.Next, Steering)
end
