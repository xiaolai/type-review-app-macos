# EPUB fixtures

None of these is cut from a book found on a development machine. Each
failure seen there is rebuilt by hand, in the tests, in public-domain or
original text.

| File | Source | Licence | Changes |
|---|---|---|---|
| `peter-rabbit-gutenberg.epub` | Project Gutenberg #14838, *The Tale of Peter Rabbit*, the "no images" EPUB | Public domain in the USA; the Project Gutenberg licence travels inside the file | Repacked with `/usr/bin/zip`, mimetype stored first |
| `wind-in-the-willows-standard-ebooks.epub` | Standard Ebooks, *The Wind in the Willows* | CC0 | Chapters 4–12 and the cover and 2× images removed from the files, the manifest, the spine and both tables of contents; repacked the same way |
| `untagged-hand-made.epub` | Written for these tests | Original | An EPUB 2 book with no `epub:type`, no roles, no guide and no landmarks: a cover page, a title page, a contents page of links, four chapters and a short note about the writer |

The two downloaded files were treated as untrusted: each was fetched into its
own empty directory and edited only by a script kept elsewhere.
