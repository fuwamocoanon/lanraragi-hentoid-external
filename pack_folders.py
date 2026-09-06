#!/usr/bin/env python3
"""
pack_folders.py — turn folder-based books into .cbz archives for LANraragi.

Companion tool for the "Hentoid External Sidecar" metadata plugin
(https://github.com/fuwamocoanon/lanraragi-hentoid-external).

LANraragi only ingests archive *files* (cbz/zip/...) — it skips loose image
folders entirely. If your library looks like:

    [Title]/1.png
    [Title]/2.png
    [Title]/contentV2.json

this script zips each such folder into "[Title].cbz". Because Hentoid drops a
contentV2.json inside the folder, it ends up *inside* the archive, which the
plugin reads via its embedded-JSON path. You can also emit a "[Title]_h.json"
sidecar next to the cbz instead (or as well), matching a sidecar-style library.

Nothing here is LANraragi-specific: it just makes cbz files. Stdlib only.
"""

import argparse
import os
import re
import shutil
import sys
import zipfile
from pathlib import Path

IMAGE_EXTS = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp",
    ".avif", ".jxl", ".tif", ".tiff", ".jfif",
}
JSON_NAMES = ("contentV2.json", "ContentV2.json")


def natural_key(s: str):
    """Sort so that 2.png < 10.png (natural/human order)."""
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


def find_images(book_dir: Path):
    """All image files under a book folder, recursively, in natural order by relative path."""
    imgs = [p for p in book_dir.rglob("*") if p.is_file() and p.suffix.lower() in IMAGE_EXTS]
    imgs.sort(key=lambda p: natural_key(str(p.relative_to(book_dir)).replace("\\", "/")))
    return imgs


def find_json(book_dir: Path):
    for name in JSON_NAMES:
        candidate = book_dir / name
        if candidate.is_file():
            return candidate
    # Fall back to a case-insensitive search at the top level only.
    for p in book_dir.iterdir():
        if p.is_file() and p.name.lower() == "contentv2.json":
            return p
    return None


def fmt_size(n: int) -> str:
    step = 1024.0
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < step or unit == "TB":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= step
    return f"{n:.1f}TB"


def pack_book(book_dir: Path, out_dir: Path, args) -> str:
    """Pack one book folder into a cbz. Returns a status string."""
    images = find_images(book_dir)
    if not images:
        return f"SKIP  (no images)      {book_dir.name}"

    json_file = find_json(book_dir)
    cbz_path = out_dir / (book_dir.name + ".cbz")

    if cbz_path.exists() and not args.overwrite:
        return f"SKIP  (cbz exists)      {cbz_path.name}"

    if args.dry_run:
        extra = " +contentV2.json" if json_file and args.json_mode in ("embed", "both") else ""
        sc = " +sidecar" if json_file and args.json_mode in ("sidecar", "both") else ""
        return f"DRY   {len(images):>4} imgs{extra}{sc}  ->  {cbz_path.name}"

    out_dir.mkdir(parents=True, exist_ok=True)
    compression = zipfile.ZIP_DEFLATED if args.compress else zipfile.ZIP_STORED
    tmp_path = cbz_path.with_suffix(".cbz.part")

    try:
        with zipfile.ZipFile(tmp_path, "w", compression=compression) as zf:
            for img in images:
                arcname = img.relative_to(book_dir).as_posix()
                zf.write(img, arcname)
            if json_file and args.json_mode in ("embed", "both"):
                zf.write(json_file, "contentV2.json")
        # Integrity check before we consider touching the originals.
        with zipfile.ZipFile(tmp_path) as zf:
            bad = zf.testzip()
            if bad is not None:
                raise zipfile.BadZipFile(f"corrupt entry: {bad}")
        os.replace(tmp_path, cbz_path)
    except Exception as e:
        if tmp_path.exists():
            tmp_path.unlink()
        return f"ERROR ({e})  {book_dir.name}"

    # Optional sidecar next to the cbz.
    if json_file and args.json_mode in ("sidecar", "both"):
        shutil.copyfile(json_file, out_dir / (book_dir.name + "_h.json"))

    # Handle the originals only after a verified successful pack.
    action = handle_original(book_dir, args)
    size = fmt_size(cbz_path.stat().st_size)
    return f"OK    {len(images):>4} imgs  {size:>8}  {cbz_path.name}   [{action}]"


def handle_original(book_dir: Path, args) -> str:
    if args.after == "keep":
        return "kept"
    if args.after == "delete":
        shutil.rmtree(book_dir)
        return "deleted"
    if args.after == "move":
        dest_root = Path(args.done_dir).expanduser().resolve()
        dest_root.mkdir(parents=True, exist_ok=True)
        target = dest_root / book_dir.name
        if target.exists():
            i = 1
            while (dest_root / f"{book_dir.name} ({i})").exists():
                i += 1
            target = dest_root / f"{book_dir.name} ({i})"
        shutil.move(str(book_dir), str(target))
        return f"moved -> {dest_root.name}"
    return "kept"


def main():
    ap = argparse.ArgumentParser(
        description="Pack folder-based books into .cbz archives for LANraragi.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  # Preview what would happen\n"
            "  python pack_folders.py \"E:/Manga/Loose\" --dry-run\n\n"
            "  # Pack, keeping contentV2.json inside each cbz, move originals to a Done folder\n"
            "  python pack_folders.py \"E:/Manga/Loose\" --after move\n\n"
            "  # Pack, write cbz to another folder, delete the originals\n"
            "  python pack_folders.py \"E:/Manga/Loose\" --out \"E:/Manga/Library\" --after delete\n\n"
            "  # Also emit a _h.json sidecar next to each cbz\n"
            "  python pack_folders.py \"E:/Manga/Loose\" --json-mode both\n"
        ),
    )
    ap.add_argument("root", help="Folder containing book subfolders (each subfolder becomes one cbz).")
    ap.add_argument("--single", action="store_true",
                    help="Treat ROOT itself as one book instead of a container of book folders.")
    ap.add_argument("--out", default=None,
                    help="Where to write the .cbz files (default: next to each source folder).")
    ap.add_argument("--json-mode", choices=("embed", "sidecar", "both"), default="embed",
                    help="Where the Hentoid JSON goes: embed inside the cbz (default), "
                         "sidecar '<name>_h.json' next to it, or both.")
    ap.add_argument("--compress", action="store_true",
                    help="Deflate-compress (default: store, since images are already compressed).")
    ap.add_argument("--overwrite", action="store_true",
                    help="Overwrite an existing .cbz of the same name (default: skip it).")

    ap.add_argument("--after", choices=("keep", "move", "delete"), default="keep",
                    help="What to do with each source folder after a successful, verified pack: "
                         "keep (default), move to --done-dir, or delete.")
    ap.add_argument("--done-dir", default=None,
                    help="Destination for --after move. Custom location, or default '<root>/Done'.")

    ap.add_argument("--dry-run", action="store_true",
                    help="Show what would happen without writing or deleting anything.")

    args = ap.parse_args()

    root = Path(args.root).expanduser().resolve()
    if not root.is_dir():
        ap.error(f"root is not a folder: {root}")

    # Default Done folder lives under root.
    if args.done_dir is None:
        args.done_dir = str(root / "Done")
    done_resolved = Path(args.done_dir).expanduser().resolve()
    out_default = Path(args.out).expanduser().resolve() if args.out else None

    if args.after == "delete" and not args.dry_run:
        print("WARNING: --after delete will permanently remove each source folder after packing.")
        try:
            if input("Type 'yes' to continue: ").strip().lower() != "yes":
                print("Aborted."); return 1
        except EOFError:
            print("Aborted (no confirmation available; re-run with --dry-run first)."); return 1

    if args.single:
        books = [root]
    else:
        books = []
        for child in sorted(root.iterdir(), key=lambda p: natural_key(p.name)):
            if not child.is_dir():
                continue
            cr = child.resolve()
            # Never process the Done folder or the output folder as if it were a book.
            if cr == done_resolved or (out_default and cr == out_default):
                continue
            books.append(child)

    if not books:
        print(f"No book folders found under {root}"); return 0

    print(f"Root: {root}")
    print(f"Books to process: {len(books)} | json-mode={args.json_mode} | after={args.after}"
          + (f" (done -> {done_resolved})" if args.after == 'move' else "")
          + (" | DRY-RUN" if args.dry_run else ""))
    print("-" * 72)

    counts = {"OK": 0, "SKIP": 0, "ERROR": 0, "DRY": 0}
    for book in books:
        out_dir = out_default if out_default else book.parent
        line = pack_book(book, out_dir, args)
        print(line)
        counts[line.split()[0]] = counts.get(line.split()[0], 0) + 1

    print("-" * 72)
    print("Summary: " + ", ".join(f"{k}={v}" for k, v in counts.items() if v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
