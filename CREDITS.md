# Third-party assets

> The app carries a shorter, user-facing version of this in **Settings ▸
> About** (`Sources/TypeReviewApp/AboutPane.swift`). This file is the long
> form for whoever maintains the app — the conversion command, the recording
> chain, the per-entry licence fields. Change one and check the other: they
> state the same facts at two different lengths, deliberately, and only the
> facts have to agree.

## Audio

### `Resources/typewriter.m4a`

- **Source**: BigSoundBank — "Typewriter #2" (sound #2835)
- **URL**: https://bigsoundbank.com/typewriter-2-s2835.html
- **License**: CC0 (public domain — no attribution legally required;
  this credit is courtesy)
- **Description**: Continuous typing session on a Hermes Precisa 305
  (Swiss 1960s desktop typewriter, known for crisp typebar action
  against a heavy steel frame), 83 s, 48 kHz.
  Recorded by Joseph SARDIN with a Tascam DR-40 + Sennheiser ME66.
- **Used by**: the `typewriter` keyboard sound pack
  (`Sources/TypeReviewKit/KeySounds.swift`). Played as ~80 ms slices
  cut at detected keystroke onsets, so each keypress sounds subtly
  different.
- **Relationship to the website**: the same recording. The web app
  ships it as OGG, which AVFoundation does not decode; this is the
  identical audio converted to mono AAC. Mono on purpose — the stereo
  position of a keystroke is applied per key from where that key
  physically sits, so a stereo source would only fight it.

  Reproduce the conversion from the website's copy with:

  ```
  ffmpeg -i ../type-review/public/sounds/typewriter.ogg \
         -ac 1 -c:a aac -b:a 96k Resources/typewriter.m4a
  ```

---

## Acknowledgement

### Mechvibes — https://github.com/hainguyents13/mechvibes (MIT)

Where the idea came from, and where the `mechvibe` pack's name came from.
Mechvibes is a keyboard sound simulator with swappable packs; this app
borrowed that shape and nothing else. Its packs are recordings mapped
per key, with a separate release file per key (`soundup` and the `-up`
entries in its `config.json`); every synthesised pack here is generated
from a noise burst and an oscillator described in
`Sources/TypeReviewKit/KeySounds.swift`, so no Mechvibes audio and no
Mechvibes code is present. Nothing is legally owed — this is a courtesy,
and an accurate one is worth more than a generous one.

---

## Bundled corpus

Text passages in `Sources/TypeReviewKit/Resources/` carry per-entry
`license` fields. Most are public domain (Twain, Thoreau, Emerson,
Marcus Aurelius, and so on); a handful are short fair-use snippets from
modern authors, credited in the app's status bar whenever one is served.
