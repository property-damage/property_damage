# Used by "mix format"
[
  # Exclude generated export goldens under test/support/fixtures: they are
  # verbatim generator output (`.exs` scripts included) and must not be
  # reformatted, or they would no longer match what the exporters emit.
  inputs:
    ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.reject(&String.starts_with?(&1, "test/support/fixtures/")),
  # Exported to downstream projects via `import_deps: [:property_damage]` so the
  # `property_damage` ExUnit test macro is formatted without parens around its
  # arguments, matching how it reads in the guides.
  export: [locals_without_parens: [property_damage: 1, property_damage: 2]]
]
