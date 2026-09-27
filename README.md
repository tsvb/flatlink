# flatlink

See every photo in a folder tree in **one DxO PhotoLab grid**.

PhotoLab's folder browser shows only the images at the top level of the folder you select. Photos
filed in subfolders — by year, by day, by camera — never appear together. `flatlink` builds a
flat folder of symlinks to every image in a tree. Open that folder in PhotoLab and it's all there.

```text
Photos/                                  PhotoLab-All/
├─ 2026/                                 ├─ 2026__2026-05-28__IMG_0001.CR3  → Photos/2026/2026-05-28/IMG_0001.CR3
│  ├─ 2026-05-28/IMG_0001.CR3    ──►     ├─ 2026__2026-05-29__IMG_0042.CR3  → …
│  └─ 2026-05-29/IMG_0042.CR3            └─ X100VI__DSCF1234.RAF            → …
└─ X100VI/DSCF1234.RAF
```

Your photos are never moved, copied or modified. The only thing the tool ever creates or removes is
symlinks inside the folder you point it at.

## Install

```bash
brew install tsvb/tap/flatlink
```

A single universal binary (Apple silicon and Intel), signed and notarized, for macOS 14 or later.
No Python or other runtime needed.

## Use

```bash
flatlink ~/Pictures/Photos ~/Pictures/PhotoLab-All
```

Then open `~/Pictures/PhotoLab-All` in PhotoLab.

Run the same command again after each import: existing links are kept and only new photos are
linked. Link names carry the path below the source, so they never collide and sort by folder.

| Option | Effect |
| --- | --- |
| `-n`, `--dry-run` | Show what would change; change nothing. Try this first. |
| `--skip-paired-jpegs` | If you shoot RAW+JPEG, leave out each JPEG that has a RAW of the same name in the same folder, so every shot appears once — as its RAW. |
| `--prune` | Remove links whose original photo has been deleted. |
| `--ext EXT` | Only link this format; repeatable: `--ext cr3 --ext jpg`. By default: JPEG, TIFF, HEIC, PNG and 24 RAW formats. |

Hidden files, the contents of packages (such as `.photoslibrary`), existing symlinks and the
destination folder itself are skipped. A file already in the destination is never replaced: it is
reported and left alone.

Exit status: `0` success, `1` some links could not be created or removed (each is named on stderr),
`64` usage error.

### Tips

- **External drives:** put the link folder on the same drive as the photos
  (`/Volumes/Photos/PhotoLab-All`), so it travels with the drive. The drive must be formatted APFS or
  Mac OS Extended — exFAT can't hold symlinks. A link folder on your Mac works too, but PhotoLab shows
  the images as missing while the drive is unplugged.
- **Large archives:** a folder of many thousands of images can make PhotoLab slow to browse. Run the
  tool once per camera or per year into separate link folders if it does.

### Where your edits are saved

PhotoLab saves your edits in a `.dop` sidecar **beside the link**, named after it
(`PhotoLab-All/2026__2026-05-28__IMG_0001.CR3.dop`), not beside the original. The original photo is
never touched. (Measured in PhotoLab 9.12.)

That makes the link folder the home of your PhotoLab edits, so:

- **Keep it.** Don't delete and rebuild the link folder once you've edited in it; re-run `flatlink`
  into the same folder instead. It only ever adds or removes symlinks, never a `.dop`.
- **Rename source folders with care.** A link's name comes from its path below the source, so
  renaming `2026-05-28/` gives its photos new links, and PhotoLab sees them as unedited. The old
  `.dop` files stay in the link folder, under the old names.
- **Other apps won't see these edits**, because they aren't beside the original. Export from
  PhotoLab to share the results.

## Why PhotoLab needs this

PhotoLab 9 lists a folder through its Filesystem plugin, which calls `NSFileManager`'s
`enumeratorAtURL:includingPropertiesForKeys:options:errorHandler:` with options `7`: skip
subdirectory descendants, skip package descendants, skip hidden files. There is no setting to change
it; the same listing feeds both the folder tree and the image grid. The code that sorts the results
does resolve symlinks and aliases, which is what this tool relies on. (Measured in PhotoLab 9.12.)

## Build from source

```bash
swift build -c release
swift test
```

Requires Xcode 16 or later. No dependencies. Releases are built, signed and notarized by
[scripts/release.sh](scripts/release.sh).

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with or endorsed by DxO. DxO and PhotoLab are trademarks of DxO Labs.
