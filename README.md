# Hentoid External Sidecar — LANraragi metadata plugin

A [LANraragi](https://github.com/Difegue/LANraragi) metadata plugin that tags your archives from
**Hentoid-style sidecar JSON files that sit next to each archive on disk** — for example
`My Archive.cbz` paired with `My Archive_h.json` in the same folder.

This is handy if you exported a [Hentoid](https://github.com/avluis/Hentoid) library (or anything
that produces the same `contentV2`-style JSON) where the metadata lives *beside* the archives rather
than *inside* them.

## Credits

The original **Hentoid** metadata plugin was made by **Durandal**, which read a `contentV2.json`
embedded *inside* the archive. This version was **updated to support the latest LANraragi versions
using Claude Opus 4.8**, and reworked to read the JSON from a sidecar file next to the archive (with
the original in-archive behaviour kept as a fallback).

## What it does

For each archive, the plugin:

1. **Reads the sidecar first** — it derives `<archive-basename>_h.json` from the archive's path and
   reads that file directly from disk. The archive itself is never opened for this.
2. **Falls back to the embedded JSON** — only if no sidecar is found, it looks *inside* the archive
   for `contentV2.json` / `ContentV2.json` (the classic Hentoid behaviour).

From the JSON it produces LANraragi tags with these namespaces:

| Hentoid attribute | LANraragi tag        |
| ----------------- | -------------------- |
| `TAG`             | *(bare tag)*         |
| `ARTIST`          | `artist:`            |
| `CIRCLE`          | `group:`             |
| `SERIE`           | `series:`            |
| `CHARACTER`       | `character:`         |
| `LANGUAGE`        | `language:`          |
| `CATEGORY`        | `category:`          |
| `url` (top level) | `source:` *(optional)* |

It can also set the archive **title** from the JSON. Both the title and the `source:` link are
toggled by plugin options (see below).

> **Note:** the sidecar must travel with the archive. If you move a `.cbz` to another folder without
> its `_h.json`, the plugin falls back to scanning inside the archive and — finding nothing — reports
> that no metadata was found. Keep the `.cbz` and its `_h.json` together.

## Installation

Copy `HentoidExternal.pm` into your LANraragi install's metadata plugin folder and **restart
LANraragi** so it loads the new plugin:

```
<LANraragi>/lib/LANraragi/Plugin/Metadata/HentoidExternal.pm
```

- **Native Windows install:** `%AppData%\LANraragi\lanraragi\lib\LANraragi\Plugin\Metadata\`
- **Docker:** copy into the plugin directory of the container / mounted plugins volume.

Then open **Plugin Configuration → Metadata**, enable **Hentoid External Sidecar**, and tick the
options you want:

- **Save archive title from the JSON**
- **Save the source URL as a `source:` tag**

## Usage

- **Single archive:** open the archive, run the plugin from the metadata plugin dropdown, then save.
- **Whole library:** **Batch operations → Use a plugin to pull metadata → Hentoid External Sidecar.**
  This saves automatically and appends to existing tags (so things like `date_added:` are preserved).

## Requirements

- LANraragi (tested on **0.9.81 "Atomica"**).
- No extra Perl modules beyond what LANraragi already ships.

## License

MIT — see [LICENSE](LICENSE). Original plugin © Durandal; sidecar adaptation contributed by the
community.
