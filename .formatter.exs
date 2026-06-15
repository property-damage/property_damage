# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  # Exported to downstream projects via `import_deps: [:property_damage]` so the
  # `property_damage` ExUnit test macro is formatted without parens around its
  # arguments, matching how it reads in the guides.
  export: [locals_without_parens: [property_damage: 1, property_damage: 2]]
]
