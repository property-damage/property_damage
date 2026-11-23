# A layer matches a misspelled module, so it changes no spec. The run report
# must list the layer with zero specs changed. The bug switch on keeps the
# misspelled layer; off runs the model whose layer matches the refund.
%PropertyDamage.Corpus.Entry{
  name: "layer_matches_no_spec",
  engine: PropertyDamage.Corpus.Engine.Next,
  system: Corpus.Scheme,
  bug: :misspelled_layer,
  model: Corpus.Next.Guardrail.MisspelledLayerModel,
  adapter: Corpus.Next.Scheme.FaultAdapter,
  expect: {:report, "specs changed: 0"},
  control: [model: Corpus.Next.Scheme.FaultModel, adapter: Corpus.Next.Scheme.FaultAdapter],
  max_commands: 8
}
