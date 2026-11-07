# Explain this test failure

Write an explanation of one failed test run for a product owner, and answer with one JSON
object in the shape given below. The product owner decides what happens next: they need to
know what went wrong, which cause is most likely, and what to tell the people who depend
on the system. They know the product well. They do not read code and do not know the test
framework.

Your only source is the bundle that follows these instructions (or the file `bundle.json`
next to this file). Use nothing else: no other file, no web search, no memory of other
runs.

## What the bundle holds

The bundle is a JSON object. It describes one failure of a property-based test: the test
generated a random sequence of commands, ran them against a system, and checked after
each step that the system still behaved as its model says it should. One check failed.

- `failure` names the kind of failure, says in plain words what that kind means, and
  lists the lines of the report's Failure section.
- `context` lists what the failed check claims and why, taken from the descriptions the
  test authors wrote. An item whose `missing` field is set is a gap line: the authors
  wrote no description there, and the item says where one belongs.
- `listing` holds the steps each target ran, in order, and the events each step
  produced. A target is one system, or one way of reaching a system, that the test ran
  the same commands against.
- `sections` holds the report's other sections, such as the projections (the state the
  test tracked) at the failure, the setup, and the command that reproduces the run.
- `modules` holds the documentation and the full source of the code behind the failure:
  the model, the checks, the commands, the events, and the adapters. An adapter is the
  test's own code that talks to the system. It can be wrong too.
- `ids` lists every id you may cite.

## Rules for citations

1. Every entry of `summary` and `talking_points` cites at least one id in `cites`, and
   every hypothesis lists at least one id in `evidence`. A step in `next_steps` cites
   nothing.
2. Cite only ids that appear in `ids`. Copy them exactly. Never build an id from parts.
3. You may also cite a line range of a module's source as `source:<Module>:<from>-<to>`,
   where `<Module>` is a module in `modules` with a `source`, and `1 <= from <= to <=
   lines`. Use a range only for code that no function id covers.
4. A gap line is missing context. It is never evidence. Do not cite an item whose
   `missing` field is set in a hypothesis's `evidence`. You may mention a gap in the
   summary when the missing description would have helped, and cite it there.
5. Cite the most specific id that supports the sentence: an event entry rather than its
   step, a step rather than a whole section.

## Rules for hypotheses

1. Give between one and four hypotheses about the cause.
2. Rank them by how likely they are: rank 1 is the most likely. Ranks run 1, 2, 3 with
   no gaps.
3. Label each with a likelihood: `likely`, `possible` or `unlikely`. A hypothesis never
   has a higher likelihood than one ranked above it.
4. Always weigh the test against the system. The fault can sit in the system, or in the
   test: its model may expect the wrong thing, or its adapter may send or read the wrong
   thing. Read the adapter's source before you rank. Say in each claim which one is at
   fault.
5. A hypothesis is a claim, not a certainty. Write "the refund probably reversed the
   whole fee", not "the cause is the refund".
6. Give each hypothesis next steps that would confirm or rule it out: a command to rerun,
   a value to check, a person to ask.

## Tone

- Write plain English for a reader who does not code. Use the product's own words, such
  as the names of its operations and its data.
- Avoid test-framework terms (projection, shrinking, adapter, generator, check, seed).
  If you need one, say what it means in the same sentence, for example "the test's
  adapter (its code that talks to the system)".
- One idea per sentence. Short sentences.
- Say what happened, not how you found it.
- Use only ASCII characters.

## The answer

Answer with one JSON object and nothing else: no text before or after it, no code fence.
The object has exactly these three keys:

```
{
  "summary": [
    {"text": "One sentence of what happened.", "cites": ["<id>", "..."]}
  ],
  "hypotheses": [
    {
      "rank": 1,
      "likelihood": "likely",
      "claim": "One or two sentences naming the cause and whether the system or the test is at fault.",
      "evidence": ["<id>", "..."],
      "next_steps": ["One step that would confirm or rule out the claim."]
    }
  ],
  "talking_points": [
    {"text": "One sentence the product owner can tell people outside the team.", "cites": ["<id>"]}
  ]
}
```

- `summary`: three to eight sentences that tell what the test did, what it expected, and
  what it saw instead, in that order.
- `hypotheses`: as in "Rules for hypotheses". `evidence` holds at least one id.
- `talking_points`: two to five sentences for people outside the team, such as a partner
  or support. Each states what is known, not a guess, and cites its evidence. Do not
  blame anyone.

The tool that applies your answer checks every id and every source range against the
bundle. If any check fails, it rejects the whole answer and lists each bad citation.
