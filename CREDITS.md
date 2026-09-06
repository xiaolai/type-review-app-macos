# Third-party assets

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

## Bundled corpus

Text passages in `Sources/TypeReviewKit/Resources/` carry per-entry
`license` fields. Most are public domain (Twain, Thoreau, Emerson,
Marcus Aurelius, and so on); a handful are short fair-use snippets from
modern authors, credited in the app's status bar whenever one is served.
