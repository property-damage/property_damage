# A refund note longer than 40 characters is silently cut to 40 by the system,
# and the model's check sees the stored note differ from the sent one. The
# smallest failing plan pays 1, then refunds 1 with a note of 41 characters.
#
# The shrunk note is compared by ignoring the `note` field: the bug depends on
# the note's length, not its content, so a shrunk plan with any note over 40
# characters is the same failure, and the comparison checks the rest of the
# plan (the payment, the refund and its amount).
%PropertyDamage.Corpus.Entry{
  name: "long_note",
  engine: PropertyDamage.Corpus.Engine.Run,
  system: Corpus.Scheme,
  bug: :long_note,
  model: Corpus.Scheme.Noted.Model,
  adapter: Corpus.Scheme.Noted.Adapter,
  minimum: [
    %{command: :pay, amount: 1},
    %{command: :refund, payment_id: :id, amount: 1, note: String.duplicate("a", 41)}
  ],
  compare: {:ignore_fields, [:note]},
  max_commands: 8
}
