# How this port works

The engineering notes for [TYPE for macOS](README.md) — why the engine was
ported rather than shared, what keeps the two implementations honest, and the
reasoning behind the parts of the AppKit surface that were not obvious.

These used to be the README, which meant someone arriving at the repository met
a design document before learning what the app was.

---

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

Regenerate them after any engine change in the web repo, by the procedure in
[Regenerating a vector](#regenerating-a-vector) below. There is no one command
that does it.

The vectors cover the RNG across six seeds, the rounding and statistics
primitives including negative halves, run metrics and per-second bins,
histograms including a combining-mark case, six seeded adaptive runs with their
planner output, both text generators, and the exact serialized bytes of a
completed profile.

That last one is a product requirement, not a nicety: a user must be able to
carry a profile between the website and this app, so the encoder here has to
reproduce the original's bytes — key order included.

## Regenerating a vector

There is no `pnpm emit:vectors`, and there never was — this document and nine
test skip messages used to say there was. Those skips are gone too: a missing
vector now throws `VectorUnavailable` and fails the suite, because the vectors
are committed and an absent one is a broken checkout rather than a
configuration. `VectorCoverageTests` asserts the reverse — that no vector ships
unread.

The vectors were produced by running the web implementation over chosen inputs
and recording what it returned, and that is still the method:

1. Write a throwaway test **inside the web repository** — not a plain script.
   `tsx` cannot load `src/ui/stats/aggregations.ts`: something in its import
   chain uses `import.meta.glob`, which is a Vite feature. Vitest has Vite's
   transform, so a `*.test.ts` file works where a script does not.
2. Read the existing vector's *input* section (`histograms`, `runTimestamps`,
   whatever that file carries), feed it to the real function, and print the
   result as JSON.
3. Paste that into the vector file and add the Swift assertion.
4. **Then break the Swift port on purpose** and watch the vector fail. A vector
   nobody has seen fail is a vector nobody knows is connected.

The per-finger section was added this way, and step 4 caught both the obvious
error (a key mapped to the wrong finger) and the arithmetic one the comment
warns about (`misses / (hits + misses)`, which counts every typo twice).

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

## Living in the menu bar

The app does not quit when its window closes, because it has a menu-bar item.
That was not true when the item was added, and the two together made no sense:
closing the window took the icon with it, so "Open TYPE" was a menu entry that
could only be reached while a window was already open.

Three things had to follow from the change. `isReleasedWhenClosed` goes false,
or reopening reaches a window that has been deallocated — the default is true
for a programmatically created window. `applicationShouldHandleReopen` brings
the window back on a Dock click. And the drawer is put back by hand: it is a
child window, so closing its parent takes it off screen while leaving this
side of it thinking the drawer is still out.

The bundle is `TYPE.app`, not `TypeReview.app`. macOS labels the Dock item
from the bundle, and the old name gave the Dock a tooltip that disagreed with
the app's own menu bar.

## The Settings window

Four things were making it look like a form rather than a Mac settings pane,
and each has a rule behind it worth keeping:

- **Help text goes under the control, small and grey — never in a third
  column.** A column of it forces the window wide enough to hold the longest
  sentence, leaves a ragged grey edge against a lot of white, and sets the
  caption at the same size as the label it is subordinate to.
- **Controls are leading-aligned in their column, not filled.** Filling makes
  every control as wide as the widest one in the pane, which is how a
  two-digit target-speed field ended up 330 points across. Text fields carry a
  width *constraint*; setting `frame.size.width` inside an autolayout grid is
  overwritten on the next pass.
- **Every pane is the same width.** A window that changes width on each
  toolbar click reads as three windows.
- **The grid is not pinned to the pane's bottom.** Pinned to both edges it
  stretches to whatever height the pane was built with — and panes are
  measured with every row visible, before the ones that do not apply are
  hidden. NSGridView puts the slack *inside a row*: a 67-point band of white
  in the middle of the pane that moved as the settings changed. The panes are
  re-measured when rows are hidden, so the window is as tall as what it holds.

### Steppers wrap unless you tell them not to

`NSStepper.valueWraps` defaults to **true**. One click up from 140 characters
per line went to 30 and took the window's shape with it; one click down from
the minimum went to the maximum. Every stepper here sets it false.

Numbers are a field and a stepper together, in both panes. The profile's
target speed had only the field, which made the same kind of value look like
two different kinds depending on which pane it was in — and the stepper has to
be moved by `refresh` alongside the field it mirrors, or its next click jumps
the value back to whatever it was built with.

## The icon set

`keyboard.badge.eye` for the app — a keyboard being watched, which is what
this does to your typing — and `keyboard.badge.ellipsis` for the menu bar.
Both are SF Symbols, which means they carry Apple's optical corrections rather
than a traced approximation of them, and the menu-bar one is a template image
so macOS inverts it for a dark bar and dims it when the bar is inactive — the
two things a hand-tinted image gets wrong.

The menu-bar symbol is sized explicitly. A symbol's default configuration
sizes by cap height, and `keyboard.badge.ellipsis` is a wide, short mark — at
the default it drew 19 by 11 points of ink and was the shortest thing in the
bar, against neighbours running 12 to 15.5. `.large` at 13 points brings it to
24 by 13.5: as tall as the taller neighbours, two points wider than the widest.
The numbers come from measuring the rendered menu bar, not from the API.

### Two icons, and why neither is derivable from the other

The app icon ships twice, from one generator.

`Resources/TypeReview.icns` is the whole picture, tile included, for **macOS 14
and 15**. Those versions draw an app icon exactly as handed over, so the
artwork has to arrive already shaped: Apple's grid, an 824-point tile on a 1024
canvas, and its own drop shadow.

`Resources/AppIcon.icon` is an Icon Composer document — a gradient and the mark
on nothing — compiled by `actool` into `Assets.car` for **macOS 26**. That
version draws app icons itself. It shapes them, lights them, and re-lights them
for light mode, dark mode and tinting, and it can only do that for an icon
supplied as *contents* rather than as a finished picture.

Handing 26 the `.icns` alone is not a cosmetic compromise, it is a visible
defect: the system fills the transparent margin around our 80.5% tile with
white and rounds the result, so the app sat in the Dock as a small blue square
inside a large cream one. That is what the second file exists to fix, and it is
why cropping one out of the other would not work — one has a tile the other
must not have.

Both `Info.plist` keys ship, which is what Notes and Music do. macOS 26 reads
`CFBundleIconName` and finds the catalogue; 14 and 15 read `CFBundleIconFile`
and find the painted tile.

`actool` also flattens the document to its own `.icns`, and the build deletes
it. It carries only four representations against the hand-drawn set's ten, so
it is not a replacement — measured, not assumed, and unchanged by lowering the
deployment target from 26.0 to 14.0.

Three assertions guard the step, because each part can fail while looking like
it worked: `actool` exits 0 having written nothing if it decides there is no
icon to compile, a catalogue can exist carrying only flattened bitmaps, and
PlistBuddy reports success for keys it did not write. The middle one greps the
compiled catalogue for `IconImageStack` — the structure that *is* the glass.

### The flat artwork

`Tools/make-icon.swift` draws both products; `make icon` runs the first through
`iconutil` and writes the second into the document. The outputs are committed,
so an ordinary build needs neither, but the artwork stays reproducible and
changing it is an edit to code.

- **The artwork simplifies as it shrinks.** `keyboard.badge.eye`'s badge and
  its rows of small keys collapse into a smudge well before 16 points, so the
  filled badge stands in below 80 pixels and the plain `keyboard.fill` below
  24.
- **The mark is fitted by rendered width, not point size** — 0.84 of the tile
  at full size, 0.90 at 32. A symbol's point size is its cap height, so sizing
  by it makes a wide mark overflow and a narrow one look lost. The widths came
  from rendering candidates side by side: at 32 pixels the badge holds together
  at 0.90 and loses the eye at 0.80, and 32 is the size that decides, because a
  Dock icon is admired at 1024 and used at 32.
- **The tile is blue glass, and the mark is cut out of it.** Five passes, each
  one something glass does: shadow, body, specular, bounce, rim. The rim is the
  one that matters — body alone is paint and body plus specular is plastic. The
  mark is punched through with `.destinationOut`, so the desktop shows through
  it; the pale edge around every cut is a shadow laid down before the punch and
  left behind by it, which is what keeps the shape readable on a dark wallpaper
  where a hole has no colour of its own.
- **Weight rose with the colour.** A shape cut out of a dark ground reads
  thinner than the same shape painted on a light one, because light bleeds
  across the cut. `.medium` on blue lands where `.regular` landed on silver.
- **The tile is a superellipse, not a rounded rectangle.** macOS icon tiles
  use a continuous corner and `NSBezierPath` has none; `|x/a|^5 + |y/b|^5 = 1`
  is the shape, and sampling it is shorter than faking it with arcs. Apple's
  grid puts an 824-point tile on a 1024 canvas, and the shadow is part of the
  artwork rather than something the Dock adds.

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

The layout asked is the **ASCII-capable** one, not simply the current one.
With a Chinese, Japanese or Korean input method active, the current layout is
the input method's own, and `UCKeyTranslate` answers with what that method
*produces*: `……` above 6, `¥` above 4, `《` and `》` on the comma and full
stop, `【】` on the brackets. Every one is a true answer to the wrong question.
An input method is a layer on top of a keyboard, and the keyboard underneath
still has `^` above 6 — which is what the keycap says. Dvorak and Colemak are
unaffected, both being ASCII-capable layouts.

The selftest checks that the layout being read from is ASCII-capable. On a
machine that only ever runs a US layout both answers agree and the check
proves little; on one with an input method active — which is where this
appeared — restoring the old call fails it.

Legends are set in the **system sans** at about a quarter of the key, not in
a monospaced face at a third. Both halves of that mattered. Monospace is the
wrong shape for a keycap and, worse, SF Mono's `⇧` and `⌘` are thin stylised
outlines rather than the solid glyphs macOS uses everywhere else — the
modifier keys were where it looked most wrong.

Every key along the outer edges carries its legend in the bottom corner
nearest the edge of the keyboard, as Apple prints them. `esc`, `fn`, `⇥`,
`⇪`, `⇧`, `↵` and `⌫` carry the glyph alone; `⌃`, `⌥` and `⌘` keep their
spelled word beneath it, since the glyph alone does not name them.

The keyboard is 93.5% of the window's width at the default setting: the drawer
window is 95% — settable at 95, 90, 85, 80 or 75 — and the case fills all but the
13 points its own padding takes. The air between the window and the drawer is
settable too, in points. The key pitch that comes out of that is found by stepping down
from an upper bound until the case fits, not by dividing — padding and gap are
each rounded to whole points, so there is no exact closed form, and the
estimated divisor this used before was a hair too large. It cost a whole point
of pitch: the keyboard drew at 53 inside a drawer sized for 54.

The gap between caps is 0.16 of the key pitch — Apple's own proportion, a
19 mm pitch with a 16 mm cap — which is 9 points at the default window's
54-point keys.

The four caps in the corners of the case have their outer corner rounded
**concentrically** with the shell: radius equal to the case's radius less the
padding between them, which comes to twice the normal cap radius. That is how
a Magic Keyboard is cut, and it is the detail that stops a grid of rounded
rectangles reading as a grid of rounded rectangles. It needed a path builder
that takes four radii — `NSBezierPath(roundedRect:)` gives every corner the
same one.

Drawn the way Apple draws the object: white chiclet caps on a silver body,
the function row and its Touch ID button, `!` printed above `1`, and
`control` / `option` / `command` spelled out under their glyphs and hugging
the outer edge of the cluster. The cap is one rounded rect in the border
colour with the face inset a point on three sides and two at the bottom —
that single asymmetric inset is the lip, and the lip is what stops a flat
rectangle reading as a rectangle. A pressed key loses the lip and moves down
by the point it lost, so it reads as travel rather than as a highlight.

Every row is exactly 15 units wide, and the last key in each row absorbs
whatever slack is left. That is how real keyboards are built — the odd sizes
are always the edge keys — and it means ANSI, ISO and JIS all come out flush
without a hand-tuned width per key per shape. The selftest checks that no row
leaves its absorber less than three quarters of a unit; it caught the JIS
bottom row overflowing by 1.5u the first time it ran. Checking the row
*totals* would have proved nothing — they are 15 by construction.

The tints are drawn as glass, not paint: each is a vertical ramp from nearly
clear at the top to its full strength at the bottom, at strengths low enough
that the cap still reads as white plastic with coloured light on it. Flat fill
at any useful opacity turns the cap into a coloured tile, and a dozen coloured
tiles shout over the passage they are supposed to annotate.

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

## What a view test cannot see

The header of live numbers — wpm, accuracy, mode — was invisible from the day
the app was written. Not hidden, not misplaced, not mis-coloured: it was laid
out at the right point, in the hierarchy, `isHidden == false`, `alphaValue ==
1`, with the right text and the right colour. Every property a test could
assert from the view tree was correct while the pixels were blank.

The typing view below it filled its **dirty rect** rather than its **bounds**,
and AppKit does not clip a view's drawing to its own bounds — it hands a view
whatever rect needs redrawing, which can be bigger. So the passage's white
background was painted over the header, every frame.

Nothing but the pixels can catch that, so the selftest now looks at them: it
renders the practice view into a bitmap, finds the label whose text ends in
"wpm", and requires that its rectangle contains pixels differing from the
background. Restoring the dirty-rect fill reports `only 0 of its pixels differ
from the background — it is covered`.

## The window, and the drawer under it

The window is sized from the text it has to hold: 60 characters per line and
10 lines, both settable, both measured from the typing font rather than
guessed — so the numbers stay true if the font changes or a display renders it
differently. No hairline under the title bar; the practice screen is a sheet
of text on a plain ground, and a rule across the top divides it from nothing.

`⌘K` slides the keyboard out from under the window and back. The main window
never changes size. The drawer is 95% of its width, centred, with ten points
of air between them — inset and separated so it reads as its own object rather
than as the window's bottom edge — and it has no background: the keyboard
floats against whatever is behind the app.

It is a separate borderless window with a clear background, attached with
`addChildWindow`. That relationship is what makes it a drawer rather than a
second window to manage: it moves, orders, miniaturises and closes with its
parent. Width and the parent's bottom edge are the only things it does not
track, so a resize is observed.

Details that each took a decision:

- **No shadow.** macOS derives a window's shadow from its frame, not from what
  it draws, so a transparent window would cast a rectangular shadow around
  nothing. The keyboard's own case supplies the edge.
- **`ignoresMouseEvents`.** The keyboard is a picture, not a control. Without
  this the transparent area swallows clicks meant for what is behind it.
- **Pinned to the bottom** of its content view, so as the window grows
  downward the keyboard travels with its lower edge and is revealed bottom
  first — a sheet coming out of a slot. Pinned to the top it would sit still
  and unroll.
- **The window is nudged up** if the drawer would open past the bottom of the
  screen, which is what Apple's own drawers did.
- **Put away in full screen**, where a drawer below the window is off the
  display entirely.

Two earlier attempts were not drawers at all, and both are worth naming
because both looked plausible. An `NSSplitView` pane trades space with the
passage and never appears or disappears. A clipping band inside the window
eats the window's own height. A drawer is, by definition, outside its parent.
(`NSDrawer`, the class that owns the name, has been deprecated since 10.13.)

### Two kinds of setting

Window shape and drawer speed live in `UserDefaults`, in their own Settings
pane, and never touch the profile. `ProfileSettings` — its fields, bounds and
defaults — is shared with the website and pinned by golden vector; a field
added there would either break those vectors or have to be invented on both
sides for something only a Mac window has. Both stores clamp on read as well
as write, so a value typed straight into `defaults write` is no more able to
produce a four-character window than a control is.

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

## The applications the keyboard stays silent in

Keystroke sound in every application means the app receives every keystroke in
every application, which is the correct moment to be uneasy. The monitor reads
`keyCode` and nothing else — never `characters` — so what reaches it is which
key, never which letter. That is a real distinction, and it is not a sufficient
one: knowing the physical keys pressed while a master password is typed is
knowing the master password.

So there are three defences, and only the third is a list.

Two of them ask, rather than remember. `IsSecureEventInputEnabled()` is true
whenever any application has claimed secure input — every password field in
macOS does, including the ones in browsers — and it is checked on the event
path, so it covers fields nobody enumerated. And any application shipping an
`ASCredentialProviderExtension` has declared itself a password manager to the
system; `GlobalKeySound.declaresCredentialProvider` reads that declaration
rather than a name. Both work for software written after this list was.

The third is `protectedApps` in `AppPreferences.swift`, and it exists because
the first two have a gap in the same place: a manager's own window is not a
password field, and an older manager may ship no extension. Vault search, a
secure note, a card number, the label on a one-time code — ordinary text
fields, at the highest stakes in the app. While one of these is frontmost the
monitor is uninstalled outright, so the events are not received at all rather
than received and discarded.

### Keeping the list honest

A list of identifiers rots quietly, and it rots in the direction that looks
fine. A wrong identifier never matches anything, so it produces no error and no
missing feature — it just silently stops protecting an application while
occupying the line that claims to. This list carried exactly that for a while:
`com.lastpass.LastPass` where the desktop app is
`com.lastpass.lastpassmacdesktop`.

`make password-managers` re-checks every entry against two sources that state
bundle identifiers outright — the Homebrew cask API, whose `quit:` and `zap`
stanzas name them so the uninstaller can find them, and the App Store lookup
API. It reports three things:

| Section | Question it answers |
|---|---|
| Per-manager coverage | Is each known manager protected by *some* entry? |
| In the list, confirmed by nothing | Is any entry unsupported by any source? |
| Found by a source, not in the list | Has a manager shipped an identifier we lack? |

The middle one is the reason the routine exists. The other two catch what is
missing, which is the failure that eventually announces itself; only that one
catches what is wrong, which is the failure that never does. Its first real run
found three: KeePassXC's legacy `org.keepassx` preferences domain, Strongbox's
paid bundle, and the LastPass container the cask still names.

It reports and never rewrites. The list decides when the machine stops
listening, so each line should be a decision somebody made — and a generator
that produced an empty list because an API changed shape would leave a green
build over no protection at all. Entries deliberately kept without a live
source, such as a legacy bundle ID or an Apple authentication agent, are
recorded with their reason in `verifiedByHand` in the tool, so the loud output
stays reserved for something genuinely unexplained.

It needs the network, so it is not part of `make test`: a gate that goes red
because a CDN was slow is a gate people learn to ignore. It exits non-zero on
drift, so it still works as one where it is wanted.

## Drift between the two implementations

Everything shared is pinned by a vector, including the settings surface itself
— defaults, both bound tables, option domains and the presets each picker
offers. That is the only thing standing between two independent
implementations and a slow divergence nobody notices until a profile fails to
load on one side.

Next: signing, notarization and distribution. Then the AppKit surface — where the earlier WKWebView shell's
signing, window, menu and settings work carries over as a design, if not as
code.
