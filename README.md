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

## The app

```sh
make run        # build the bundle and launch it
make selftest   # drive a full run through the real input path
make test       # the Kit against the vectors
```

`TypingView` is CoreText, not `NSTextView`, for two reasons.

**Input goes through `NSTextInputClient`.** Reading `NSEvent.characters` in
`keyDown` is the tempting shortcut and it is the one silent data-corruption bug
available here: during CJK composition every keystroke reports its
pre-composition character, so the profile would fill with letters the user
never typed. Going through the input context means marked text is drawn as
marked text, only committed characters reach the engine, and the candidate
window is anchored under the caret. The web version can only *drop*
composition keystrokes — this is the difference between protecting CJK users
and serving them.

**Layout does not depend on typing status.** Colour is applied per glyph run at
draw time, so the `CTFrame` is built once per passage and reused for every
keystroke, and the caret is placed by asking a specific line for its offset —
which is what keeps it one line tall at a wrap boundary, where a space belongs
to two line fragments at once.

Results replace the passage in place when a run finishes — after a run the
number you want is where your eyes already are, and Enter starts the next one
without anything moving. Statistics get their own window (⌘2) rather than a
route, which is the Mac answer to "show me this alongside".

Day-level statistics are computed in local calendar days, and that is the one
part of the engine whose answer depends on where the machine is. The vectors
are therefore generated under two timezones — one with daylight saving, one
without — and each records the zone it came from. Subtracting 86,400,000 ms
instead of a calendar day gives the wrong date twice a year, but only when the
time of day is within an hour of midnight, which is why the vector needed
anchors just after midnight spanning a spring-forward before it could see the
difference.

The Settings window (⌘,) is hand-rolled AppKit — SwiftUI's `Settings` is a
`Scene` and cannot exist in an `NSApplication.shared.run()` host. Every write
goes through the engine's `validateSettings`, by round-tripping through the
serializer first, so a control cannot put a value into the profile that the
loader would later refuse; and a change made mid-run is *staged* rather than
applied, because restarting would throw away the paragraph the user is halfway
through.

No control emits a value merely because it displayed one. An imported profile
may legally hold a 600-second duration, which the picker has no preset for, so
it shows as `Custom (600)` — clamping on display would rewrite data the user
never touched, and the next unrelated edit would persist the rewrite.

The Appearance and Sound panes the website has are deliberately absent: this
app follows the system appearance rather than shipping four hand-built themes,
and no audio is ported yet.

## The on-screen keyboard

The clearest case for having gone native. The website cannot ask which
keyboard is attached, so it sniffs `navigator.userAgent` for "Mac", picks one
of two hand-drawn pictures, and hard-codes QWERTY, Colemak and Dvorak character
tables by hand — 485 lines with no ISO row and no JIS row, meaning European and
Japanese typists are shown a keyboard they do not own.

Here the system answers. `KeyboardGeometry` holds *positions* only, about a
fifth the size and covering three shapes instead of two; every label comes from
`UCKeyTranslate` at draw time, and the shape from `KBGetLayoutType`. Switching
to Dvorak in System Settings relabels the view, and nothing in this code knows
what Dvorak is. That is also why the website's "keyboard layout" and "keymap"
settings do not appear in this app's Settings window: the system already knows,
so it stops asking.

Keys are tinted by confidence against the user's target speed rather than
relative to their own slowest key. A relative scale paints the whole keyboard
warm the moment timings cluster, and answers "which key is worst" when the
useful question is "which keys are behind target". Error rate overrides the
speed ramp, because speed and accuracy are different problems and one colour
ramp cannot say both.

## The corpus

The 189 curated quotes and the code snippets ship inside the Kit as resources —
domain data, not app chrome, and the same bytes the website serves. `⌘4`–`⌘8`
switch source: Auto, Quotes, Code, Library, Generated.

Both corpus sources draw from the *session's* RNG rather than one of their own.
That is what keeps a seeded session reproducible in sequence rather than only
run by run, and it is why the picker's single draw is pinned by vector: one
extra draw shifts every later passage.

The generators remain the fallback and always will be. A six-letter lesson has
no real sentence available, and a timed run needs more text than any quote
holds — so "no passage" is never an outcome the app can reach.

## The library

`⌘3` opens a window for the user's own documents. A `.txt` or `.md` file
dropped on it — or chosen through the panel, or pasted — becomes practice
text.

The Markdown path is a stripper, not a parser, and **rule order is the whole
subtlety**. Images have to be dropped before links, or `![alt](url)` becomes
the word "alt": text the document never contained. Emphasis has to run after
the per-line markers, or a list bullet is read as an italic. Every ordering
mistake produces plausible English, which is exactly why it is pinned by
vector rather than by hand-written expectations — a test written from the same
misunderstanding as the code would agree with it. Swapping the image and link
rules is caught by the vector on `see ![a photo](p.png) here`.

Two deliberate departures from the website, both because the host is
different. The library is a JSON file beside the profile rather than
IndexedDB, so nothing evicts it and the user can back it up or read it. And
choosing a source explicitly now drops the alphabet filter: someone early in
the curriculum who picks Library or Code was silently served generated words,
because every real passage uses letters their alphabet has not unlocked. In
`auto` the curriculum still rules — an early learner should not be handed
letters they have never been taught.

## Drift between the two implementations

Everything shared is pinned by a vector, including the settings surface itself
— defaults, both bound tables, option domains and the presets each picker
offers. That is the only thing standing between two independent
implementations and a slow divergence nobody notices until a profile fails to
load on one side.

Next: signing, notarization and distribution. Then the AppKit surface — where the earlier WKWebView shell's
signing, window, menu and settings work carries over as a design, if not as
code.
