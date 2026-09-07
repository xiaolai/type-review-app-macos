# TYPE for macOS · [type.review](https://type.review)

Typing practice that **adapts to the keys you actually miss** — and, if you
want it, a keyboard that sounds like a keyboard in every app on your Mac.

A native Swift port of [type.review](https://type.review). No web view, no
account, no server, no telemetry.

## What you get

- **Adaptive mode** — starts you on a small alphabet and unlocks more letters
  as each one gets fast and accurate, so you drill weak keys without having to
  decide which ones they are.
- **Benchmark mode** — real prose, ended by a word count or a timer.
- **Text worth typing** — public-domain quotes and passages, code snippets,
  your own `.txt` and `.md` files, or generated drills. `Auto` picks for you.
- **Per-key statistics** — speed and accuracy for every key, with the history
  behind them.
- **An on-screen keyboard**, optional, coloured by how well you know each key
  and lit as you press them.
- **Keystroke sound, optionally everywhere.** Seven packs — three synthesised
  mechanical profiles, a real typewriter recording, a muted one, a laptop one,
  and off. The synthesised ones sound the key coming back up as well as going
  down; the typewriter does not, because a typebar returns almost silently.
- **Lives in the menu bar.** Close the window and it stays; it can start at
  login, hide its Dock icon, and be summoned with a shortcut from any app.
- **Your data is a file you can point at.** One JSON profile under
  Application Support, revealed in Finder from Settings, and importable back.

## Requirements

macOS 14 or later, on Apple silicon. `make` builds for the machine it runs
on; there is no universal binary yet.

## Installing

There is no release build yet. Until there is, build it:

```sh
git clone https://github.com/xiaolai/type-review-app-macos
cd type-review-app-macos
make          # builds TYPE.app in the project directory
open TYPE.app
```

`make` needs the Swift toolchain that ships with Xcode or the Command Line
Tools. A Homebrew cask and a Mac App Store release are both planned; the
notes on how those two differ are in [ARCHITECTURE.md](ARCHITECTURE.md).

## Sound in every app, and what it costs

Playing a sound for keys pressed in *other* applications means the app has to
be told about those keys, which macOS gates behind **Input Monitoring**. The
setting is off until you switch it on, and switching it on is what asks.

What the app does with that permission is worth stating plainly, because you
should not have to take it on trust:

- It reads **which key** moved and nothing else — the key code, never the
  character. It cannot tell an `a` from a `q`, or a password from a sentence.
- While **any password manager is frontmost the monitor is removed**, not
  muted. The events are not delivered at all. There is a maintained list, and
  any app that declares itself a credential provider to the system is covered
  whether or not it is on that list.
- Every **secure text field** in macOS silences it, including ones nobody
  thought to enumerate, because the check asks the system rather than a list.
- Nothing is stored, buffered, or sent anywhere. The only output is one audio
  buffer per keystroke.

You can also mute individual apps from Settings or from the menu bar.

## Privacy

No analytics, no telemetry, no accounts. The app makes no network requests of
its own — it links no networking framework and contains no HTTP client; the
only thing that leaves it is the `type.review` link in About, which hands a URL
to your browser when you click it. The profile lives on your Mac in one file
you can read, back up, or delete.

## The engine is the website's, checked

The typing engine — the adaptive planner, the metrics, the profile format — is
ported from the TypeScript that runs [type.review](https://type.review), and
pinned to it by golden vectors: the same inputs must produce byte-identical
output on both sides. A score earned here means what it means there.

[ARCHITECTURE.md](ARCHITECTURE.md) is the long version: why it was ported
rather than shared, what the vectors do and do not catch, and the reasoning
behind the parts of the Mac surface that were not obvious.

## Building and testing

```sh
make test         # the port against the golden vectors
make              # TYPE.app, signed if the identity is in the keychain
make appstore     # the sandboxed variant
make version      # what a build would call itself
```

## Licence

MIT for the code. The bundled passages and the typewriter recording carry
their own terms — see [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md).
