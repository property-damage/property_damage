# Small models over the fixture commands, one per purpose.

require PropertyDamage.Next.Test.Fixtures.Models

alias PropertyDamage.Next.Test.Fixtures, as: F

F.Models.defmodel(F.ProbeModel, [F.Probe])
F.Models.defmodel(F.ChainModel, [F.Chain])
F.Models.defmodel(F.OptsModel, [{F.OptsEcho, command_opts: [max_share: 0.25]}])
F.Models.defmodel(F.WeightedModel, [{F.Probe, weight: 9}, {F.Plain, weight: 1}])
F.Models.defmodel(F.NumberFieldModel, [F.NumberField])
F.Models.defmodel(F.RangeFieldModel, [F.RangeField])
F.Models.defmodel(F.StructGeneratorModel, [F.StructGenerator])
F.Models.defmodel(F.SingleGeneratorModel, [F.SingleGenerator])
F.Models.defmodel(F.FromReturnsFromModel, [F.FromReturnsFrom])
F.Models.defmodel(F.UnknownFromModel, [F.UnknownFrom])
F.Models.defmodel(F.CycleFromModel, [F.CycleFrom])
F.Models.defmodel(F.PlainFromModel, [F.PlainFrom])
F.Models.defmodel(F.DelegatedFromModel, [F.DelegatedFrom])
