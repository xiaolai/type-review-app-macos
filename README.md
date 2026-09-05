# type.review for macOS

A native Swift app for [type.review](https://type.review). No web view, no
JavaScript, no cross-language bridge — the typing engine is ported to Swift and
kept honest against the original by golden vectors.

```sh
swift test     # the port against the vectors
swift build
```

## Why a port, and how it stays correct

The web app's engine is ~2,700 lines of pure TypeScript. Sharing it would mean
embedding JavaScriptCore and shipping a bundled artefact from another repo;
porting it means one language here, at the cost of a second implementation of
the same rules.

That cost is only acceptable if divergence is caught mechanically, because
every way this port can go wrong is silent:

| Trap | What the obvious Swift does | What JavaScript does |
|---|---|---|
| `mulberry32` | `Int32` + arithmetic `>>` propagates the sign bit | `>>>` is logical; streams diverge above 2³¹ |
| `Math.round` | `.toNearestOrAwayFromZero` sends −2.5 to −3 | ties break toward +∞, so −2.5 is −2 |
| `x ** y` | repeated multiplication: `0.3*0.3*0.3` = 0.027 | `Math.pow` gives 0.026999999999999996 |
| Hashed containers | `Set`/`Dictionary` order changes per launch | `Map` preserves insertion order |
| Sort stability | `sorted` is documented as *not* stable | `Array.sort` is stable since ES2019 |
| Object key order | `Dictionary` has none; `JSONEncoder` guarantees none | insertion order, but integer-like keys hoist ascending |
| Number printing | `Double(1.7e12).description` is `"1.7e+12"` | `JSON.stringify` gives `1700000000000` |
| JSON booleans | `NSNumber` reports `true` as a number | `typeof` tells them apart |
| Lone surrogates | Foundation refuses the JSON text | `JSON.parse` accepts it |
| String indexing | `Character` is a grapheme cluster | positions are UTF-16 code units |

None of those fail a review, and the first one passes every test the original
suite had. So `Tests/TypeReviewKitTests/Vectors/` holds conformance data
generated from the running TypeScript engine, and the tests compare **exactly**
— no tolerances, since both sides run the same IEEE operations in the same
order.

Regenerate after any engine change in the web repo:

```sh
cd ../type-review && pnpm emit:vectors
```

The vectors cover the RNG across six seeds, the rounding and statistics
primitives including negative halves, run metrics and per-second bins,
histograms including a combining-mark case, six seeded adaptive runs with their
planner output, both text generators, and the exact serialized bytes of a
completed profile.

That last one is a product requirement, not a nicety: a user must be able to
carry a profile between the website and this app, so the encoder here has to
reproduce the original's bytes — key order included.

## Layout

```
Sources/TypeReviewKit   the domain layer: typing loop, metrics, adaptive
                        planner, corpus, profile codec. No AppKit.
Sources/TypeReviewApp   the AppKit surface.
Tests/…/Vectors         generated from the TypeScript engine; the contract.
```

The Kit/App split is the same separation the original enforces, for the same
reason: the part that must be exhaustively testable should not be able to
import a window.

## Status

Ported and verified against the vectors:

- `Mulberry32`, JavaScript rounding semantics, `mean`, `stdDev`, `kogasa`
- `TextInput` — the typing loop, step log, pause capping, stop-on-error and
  confidence modes, newline skipping
- `binBySecond`, `computeRunMetrics`, `computeConsistency`, `computeWpmStdDev`
- `histogramFromSteps`, `EmaFilter`, `buildBigramStatsMap`, `deriveKeyStats`,
  `Target`, `planLesson`

### Two defences, one proven and one not

`OrderedMap` exists because `deriveKeyStats` accumulates hit-weighted floating
point sums while traversing the bigram map. Substituting a `Dictionary` and
running the suite three times produced **8, 8 and then 4 failures** — not merely
different from the website, but different between launches of the same binary.
The ordered traversal removes that, and the vectors prove it.

The stable tie-break in the weak-bigram ranking is *not* provable here today. A
scenario with 48 bigrams at identical confidence still passes with a plain
`sorted(by:)`, because Swift's stdlib sort is a timsort variant that happens to
be stable — while the documentation explicitly declines to guarantee it. The
explicit index tie-break stays: it costs nothing, and the alternative is
depending on an implementation detail Apple has reserved the right to change,
where the symptom would be users being told to drill different bigrams than the
website shows.

### Byte identity

`serializeProfileString` reproduces the website's bytes exactly — the test
compares against a 4,858-byte reference profile and points at the first
diverging offset when it fails. That is a product requirement, not a purity
exercise: a user exports from the site and imports here, and the receiving side
validates with a check that rejects the entire profile over one unexpected key.

Two things make it exact. `JSONWriter` keeps object keys ordered and applies
JavaScript's own rule that integer-like keys hoist ahead of the rest in
ascending order — with numbers enabled, a passage produces bigrams like `"12"`.
And whole numbers print without a fractional part, since a timestamp rendered
as `1.7e+12` is a different file.

Verified by moving `adaptive` to the end of the settings object, which is what
the site's own validator does on load: the test fails at offset 60 and prints
both sides.

### On vectors that do not bite

Five times now, a vector has agreed with the port while failing to detect the
bug it existed for. The six-run `Session` vector was the worst: it originally
replayed one finished run six times because the emitter never called `start()`,
then typed at a uniform cadence so every run's histogram was identical, then
varied gently enough that every timing still cleared the mastery threshold and
the unlock progression came out the same whichever order history was replayed
in. Only alternating 110/460 ms — straddling the threshold — made a
newest-first replay fail, and then it failed 38 assertions.

So each defence here has been checked by planting the bug it guards against.
Where that could not be done, the README says so rather than implying
coverage.

`deserializeProfile` and the validators are checked against 34 cases covering
the rejection surface — unknown keys at four levels, out-of-range and
wrong-typed fields, a version from the future, the v1 migration, and an
over-cap histogram, which degrades to an empty histogram rather than
discarding the profile.

One documented divergence: JavaScript's `JSON.parse` accepts an unpaired
surrogate because a JS string may hold one, while Foundation refuses the text
outright because a Swift String may not. Both verdicts are `corrupt`; they
differ only in how far the payload gets first.

Next: the AppKit surface. Then the AppKit surface — where the earlier WKWebView shell's
signing, window, menu and settings work carries over as a design, if not as
code.
