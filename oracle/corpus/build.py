"""Build and verify the frozen, distributable A0 parser corpus.

The upstream byte hashes pin the editions. No network access is used by
``--verify``. Snapshot capture is explicit because the live library can change.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import shutil
import struct
import urllib.request
import zipfile
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SOURCES = {
    "aq": {
        "url": "https://www.gutenberg.org/cache/epub/25332/pg25332.txt",
        "catalog": "https://www.gutenberg.org/ebooks/25332",
        "sha256": "997442c1d041cc731d57bd164078a1dd6e98a5fe0eb9b6ec8b202edc3d0a5a38",
        "title": "阿Ｑ正傳",
        "author": "魯迅 (1881–1936)",
        "language": "zh",
        "rights": "Project Gutenberg catalog: public domain in the USA; original work copyright expired",
        "output": "books/aq.txt",
    },
    "jekyll": {
        "url": "https://www.gutenberg.org/cache/epub/43/pg43.txt",
        "catalog": "https://www.gutenberg.org/ebooks/43",
        "sha256": "b43448a88391591f9cf82b25553df00faf47a2752a873185fcdd1156eebdb990",
        "title": "The Strange Case of Dr. Jekyll and Mr. Hyde",
        "author": "Robert Louis Stevenson (1850–1894)",
        "language": "en",
        "rights": "Project Gutenberg catalog: public domain in the USA; original work copyright expired",
        "output": "books/jekyll.txt",
    },
    "rulin": {
        "url": "https://www.gutenberg.org/cache/epub/24032/pg24032.txt",
        "catalog": "https://www.gutenberg.org/ebooks/24032",
        "sha256": "98a08c88b154cfef2e6a4436f124b1e29254839c04cf0bc4538ce1fc87610393",
        "title": "儒林外史 (first 200,000 Unicode code points)",
        "author": "吳敬梓 (1701–1754)",
        "language": "zh",
        "rights": "Project Gutenberg catalog: public domain in the USA; original work copyright expired",
        "output": "books/rulin_first_200k.txt",
    },
    "french": {
        "url": "https://www.gutenberg.org/cache/epub/26812/pg26812.txt",
        "catalog": "https://www.gutenberg.org/ebooks/26812",
        "sha256": "e9f2e72e26880c7e5d17e55ea75ecc4ba9eb0d7dc7d95a67345d7b06f93a29d0",
        "title": "Un coeur simple",
        "author": "Gustave Flaubert (1821–1880)",
        "language": "fr",
        "rights": "Project Gutenberg catalog: public domain in the USA; original work copyright expired",
        "output": "books/un_coeur_simple.txt",
    },
    "kokoro": {
        "url": "https://www.aozora.gr.jp/cards/000148/files/773_ruby_5968.zip",
        "catalog": "https://www.aozora.gr.jp/cards/000148/card773.html",
        "sha256": "c55d7bf6c7cc5bd960ce291949f38cae9ba6a672a6142c3b9e1a9f5a159fa4c4",
        "title": "こころ",
        "author": "夏目漱石 (1867–1916)",
        "language": "ja",
        "rights": "Aozora Bunko: author's copyright expired; redistribution permitted by its file-use guidelines",
        "output": "books/kokoro_aozora.txt",
    },
}
SNAPSHOTS = {
    "aq_complete": "e3f53d01f830aedf",
    "bovary_partial": "bovary-terra",
}
SECRET = re.compile(
    rb"(?:sk-[A-Za-z0-9_-]{12,}|Bearer\s+[A-Za-z0-9._-]{20,}|"
    rb"NAS_DEFAULT_KEY|BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|"
    rb"xox[baprs]-[A-Za-z0-9-]{12,}|AIza[A-Za-z0-9_-]{25,})",
    re.I,
)


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def put(relative: str, raw: bytes) -> None:
    path = ROOT / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw)


def upstream(name: str, source_dir: Path | None) -> bytes:
    spec = SOURCES[name]
    if source_dir is None:
        req = urllib.request.Request(
            spec["url"], headers={"User-Agent": "Thusfar corpus maintainer (public-domain fixture)"}
        )
        with urllib.request.urlopen(req, timeout=90) as response:
            raw = response.read()
    else:
        raw = (source_dir / (name + (".zip" if name == "kokoro" else ".txt"))).read_bytes()
    if digest(raw) != spec["sha256"]:
        raise ValueError(f"{name}: upstream edition changed; review before changing the pinned hash")
    return raw


def pg_body(raw: bytes) -> str:
    source = raw.decode("utf-8-sig")
    start = re.search(r"^\*\*\* START OF .* EBOOK .*\*\*\*\s*$", source, re.M)
    if start is None:
        raise ValueError("Project Gutenberg start marker missing")
    end = re.search(r"^\*\*\* END OF .* EBOOK .*\*\*\*\s*$", source[start.end():], re.M)
    if end is None:
        raise ValueError("Project Gutenberg end marker missing")
    body = source[start.end():start.end() + end.start()].lstrip("\r\n")
    body = re.sub(r"^Produced by [^\r\n]+\r?\n+(?:\r?\n)*", "", body, count=1)
    body = body.strip("\r\n") + "\n"
    if "Project Gutenberg" in body:
        raise ValueError("Source license or trademark text remains in derivative")
    return body


def books(source_dir: Path | None) -> None:
    for name, spec in SOURCES.items():
        raw = upstream(name, source_dir)
        if name == "kokoro":
            with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                body = archive.read("kokoro.txt").decode("shift_jis")
        else:
            body = pg_body(raw)
            if name == "rulin":
                if len(body) < 200_000:
                    raise ValueError("The pinned 儒林外史 edition is shorter than 200,000 characters")
                body = body[:200_000]
        put(spec["output"], body.encode("utf-8"))


def png(seed: int) -> bytes:
    width = height = 64
    state = seed
    pixels = bytearray()
    for _ in range(height):
        pixels.append(0)
        for _ in range(width * 3):
            state = (1664525 * state + 1013904223) & 0xFFFFFFFF
            pixels.append(state >> 24)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(pixels), level=9)) + chunk(b"IEND", b""))


def epub_file(name: str, items: list[tuple[str, bytes]]) -> None:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as archive:
        for path, raw in items:
            info = zipfile.ZipInfo(path, date_time=(2000, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_STORED if path == "mimetype" else zipfile.ZIP_DEFLATED
            archive.writestr(info, raw, compresslevel=9)
    put("synthetic/" + name, out.getvalue())


def epub_common(opf: str, nav: str, chapters: list[tuple[str, str]], images: list[tuple[str, bytes]]) -> list[tuple[str, bytes]]:
    container = ('<?xml version="1.0" encoding="UTF-8"?>'
                 '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
                 '<rootfiles><rootfile full-path="OEBPS/content.opf"'
                 ' media-type="application/oebps-package+xml"/></rootfiles></container>')
    return ([('mimetype', b'application/epub+zip'),
             ('META-INF/container.xml', container.encode()),
             ('OEBPS/content.opf', opf.encode()),
             ('OEBPS/nav.xhtml', nav.encode())]
            + [('OEBPS/' + p, t.encode("utf-8")) for p, t in chapters]
            + [('OEBPS/images/' + p, raw) for p, raw in images])


def synthetic() -> None:
    put("synthetic/unicode_mixed_newlines.txt", (
        "序言\r\n𠮷野家遇见𠀋和👩🏽‍🚀。\n第二章　雨夜\r全角空格：\u3000\u3000句中空格。\r\n"
        "组合字符：e\u0301；独立 emoji：😀；家庭：👨‍👩‍👧‍👦。\u2028行分隔\u2029段分隔\n"
        "NBSP:\u00a0间隔；制表符:\t末尾\n"
    ).encode("utf-8"))
    put("synthetic/empty_chapters.txt", "第一章\n\n第二章\n\n第三章\n尾声\n".encode())
    put("synthetic/preface_only.txt", "序言\n只有前言，没有正文。\n这行仍属于前言。\n".encode("utf-8"))
    put("synthetic/long_paragraph.txt", ("第一章　长段\n" + "阿𠮷看见月光，随后继续向前。" * 10_000 + "\n").encode("utf-8"))
    encoded = "第二章　编码\n阿Q说：天气晴朗，见到赵太爷。\n"
    put("synthetic/encoding_gbk.txt", encoded.encode("gbk"))
    put("synthetic/encoding_utf8_bom.txt", b"\xef\xbb\xbf" + encoded.encode("utf-8"))
    put("synthetic/encoding_utf16_le.txt", b"\xff\xfe" + encoded.encode("utf-16-le"))
    put("synthetic/encoding_utf16_be.txt", b"\xfe\xff" + encoded.encode("utf-16-be"))
    put("synthetic/empty.txt", b"")

    opf = ('<?xml version="1.0" encoding="UTF-8"?>'
           '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
           '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
           '<dc:identifier id="id">urn:thusfar:synthetic:notes-image</dc:identifier>'
           '<dc:title>脚注与插图测试书</dc:title><dc:creator>Thusfar test corpus</dc:creator>'
           '</metadata><manifest>'
           '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
           '<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
           '<item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>'
           '<item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>'
           '<item id="figure" href="images/figure.png" media-type="image/png"/>'
           '</manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>')
    nav = ('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
           '<body><nav epub:type="toc"><ol><li><a href="ch1.xhtml#start">前言与正文</a></li>'
           '<li><a href="ch2.xhtml">空章</a></li></ol></nav></body></html>')
    chapters = [
        ("ch1.xhtml", '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1 id="start">前言</h1>'
         '<p>阿𠮷在河边看见一幅画<a href="#fn1"><sup>1</sup></a>，又遇见😀。</p>'
         '<img src="images/figure.png" alt="一幅彩色插图"/>'
         '<p id="fn1">1 这是脚注，解释河边的画。</p><h2>第一章</h2><p>正文开始。</p></body></html>'),
        ("ch2.xhtml", '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>第二章　空章</h1>'
         '<p>　　</p></body></html>'),
    ]
    epub_file("footnote_illustration.epub", epub_common(opf, nav, chapters,
              [("cover.png", png(11)), ("figure.png", png(29))]))

    opf2 = ('<?xml version="1.0" encoding="UTF-8"?>'
            '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:identifier id="id">urn:thusfar:synthetic:scrambled-toc</dc:identifier>'
            '<dc:title>乱序目录测试书</dc:title><dc:creator>Thusfar test corpus</dc:creator>'
            '</metadata><manifest>'
            '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
            '<item id="c1" href="first.xhtml" media-type="application/xhtml+xml"/>'
            '<item id="c2" href="second.xhtml" media-type="application/xhtml+xml"/>'
            '<item id="c3" href="third.xhtml" media-type="application/xhtml+xml"/>'
            '</manifest><spine><itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/>'
            '</spine></package>')
    nav2 = ('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
            '<body><nav epub:type="toc"><ol>'
            '<li><a href="third.xhtml#third">第三章先列</a></li>'
            '<li><a href="missing.xhtml#lost">不存在的章</a></li>'
            '<li><a href="first.xhtml#first">第一章后列</a><ol>'
            '<li><a href="second.xhtml#second">第二章嵌套</a></li></ol></li>'
            '</ol></nav></body></html>')
    chapters2 = [
        ("first.xhtml", '<html><body><h1 id="first">第一章</h1><p>先发生的事情。</p></body></html>'),
        ("second.xhtml", '<html><body><h1 id="second">第二章</h1><p>随后发生的事情。</p></body></html>'),
        ("third.xhtml", '<html><body><h1 id="third">第三章</h1><p>最后发生的事情。</p></body></html>'),
    ]
    epub_file("scrambled_toc.epub", epub_common(opf2, nav2, chapters2, []))


def capture_snapshots(source_root: Path) -> None:
    for label, source_id in SNAPSHOTS.items():
        source = source_root / source_id
        target = ROOT / "snapshots" / label
        if not (source / "book.json").is_file() or not (source / "status.json").is_file():
            raise FileNotFoundError(f"{source}: expected 1.7.x book and status files")
        state = json.loads((source / "status.json").read_text())["state"]
        expected_state = "done" if label == "aq_complete" else "paused"
        if state != expected_state:
            raise ValueError(f"{source}: expected {expected_state} state, got {state}")
        if (source / "notebook.json").exists():
            raise ValueError(f"{source}: personal notebook must not enter the public corpus")
        if target.exists():
            shutil.rmtree(target)
        for top in ("book.json", "kg.json", "status.json", "source.txt"):
            path = source / top
            if path.is_file():
                copy_public_file(path, target / top)
        for folder in ("work", "mentions"):
            for path in sorted((source / folder).rglob("*.json")) if (source / folder).exists() else []:
                copy_public_file(path, target / path.relative_to(source))
    make_annotated_overlay()


def copy_public_file(source: Path, target: Path) -> None:
    raw = source.read_bytes()
    if SECRET.search(raw):
        raise ValueError(f"Potential secret in {source.name}; snapshot capture stopped")
    if source.suffix == ".json":
        json.loads(raw)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(raw)


def make_annotated_overlay() -> None:
    book = json.loads((ROOT / "snapshots/aq_complete/book.json").read_text())
    block = next(b for b in book["blocks"] if b["k"] == "p" and "阿Q" in b["t"] and len(b["t"]) > 30)
    quote = block["t"][:min(18, len(block["t"]))]
    start = block["o"]
    end = start + len(quote.encode("utf-16-le")) // 2
    if end > book["len"]:
        raise ValueError("Invalid synthetic notebook anchor")
    stamp = 1_790_294_400.0
    note = [{
        "id": "fixture-aq-note-0001", "kind": "note", "start": start, "end": end,
        "quote": quote, "text": "重读时留意这一句。", "deleted": False,
        "knowledge_cutoff": end, "revision": 1, "operation": "fixture-aq-op-0001",
        "created": stamp, "updated": stamp,
    }]
    put("snapshots/aq_notebook_overlay.json", (json.dumps(note, ensure_ascii=False, indent=2) + "\n").encode())


def make_api_annotated_snapshot(*, force: bool) -> None:
    if __package__:
        from .annotate_snapshot import write
    else:
        from annotate_snapshot import write
    write(force=force)


def api_code_sha256() -> dict[str, str]:
    if __package__:
        from .annotate_snapshot import PINNED_CODE_SHA256
    else:
        from annotate_snapshot import PINNED_CODE_SHA256
    return PINNED_CODE_SHA256


def artifact_files() -> list[Path]:
    folders = [ROOT / "books", ROOT / "synthetic", ROOT / "snapshots"]
    return sorted(p for folder in folders if folder.exists() for p in folder.rglob("*") if p.is_file())


def write_manifest() -> None:
    files = {}
    for path in artifact_files():
        raw = path.read_bytes()
        files[str(path.relative_to(ROOT))] = {"bytes": len(raw), "sha256": digest(raw)}
    manifest = {
        "schema": 1,
        "description": "Frozen A0 parser and 1.7.x compatibility fixtures; hashes cover raw bytes.",
        "generated_by": "oracle/corpus/build.py",
        "sources": SOURCES,
        "synthetic": {"rights": "MIT (this repository)", "origin": "deterministic standard-library generator in build.py"},
        "snapshots": {
            "aq_complete": {"origin": "local 1.7.x library/e3f53d01f830aedf", "state": "done", "rights": "public-domain source text; historical model output", "personal_data": False},
            "aq_annotated": {"origin": "isolated aq_complete copy; synthetic fixture note persisted by actual Python 1.7.5 HTTP notebook PUT with fixed clock", "state": "done with 1 API-written note", "rights": "public-domain source text; historical model output; MIT fixture note", "personal_data": False, "api_code_sha256": api_code_sha256()},
            "bovary_partial": {"origin": "local 1.7.x library/bovary-terra", "state": "paused", "rights": "public-domain source text; historical model output", "personal_data": False},
            "aq_notebook_overlay": {"origin": "synthetic note on real 阿Q snapshot", "state": "synthetic", "rights": "MIT (this repository)", "personal_data": False},
        },
        "files": files,
    }
    (ROOT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def verify() -> None:
    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    if manifest["snapshots"]["aq_annotated"].get("api_code_sha256") != api_code_sha256():
        raise ValueError("Annotated snapshot API code provenance differs from its pinned generator")
    listed = set(manifest["files"])
    actual = {str(p.relative_to(ROOT)) for p in artifact_files()}
    required = {spec["output"] for spec in SOURCES.values()} | {
        "synthetic/unicode_mixed_newlines.txt", "synthetic/empty_chapters.txt",
        "synthetic/preface_only.txt", "synthetic/long_paragraph.txt",
        "synthetic/encoding_gbk.txt", "synthetic/encoding_utf8_bom.txt",
        "synthetic/encoding_utf16_le.txt", "synthetic/encoding_utf16_be.txt",
        "synthetic/empty.txt", "synthetic/footnote_illustration.epub",
        "synthetic/scrambled_toc.epub", "snapshots/aq_complete/book.json",
        "snapshots/aq_complete/status.json", "snapshots/aq_annotated/book.json",
        "snapshots/aq_annotated/status.json", "snapshots/aq_annotated/notebook.json",
        "snapshots/bovary_partial/book.json",
        "snapshots/bovary_partial/status.json", "snapshots/aq_notebook_overlay.json",
    }
    if not required <= actual:
        raise ValueError(f"Required corpus fixtures missing: {sorted(required - actual)}")
    if listed != actual:
        raise ValueError(f"Artifact set differs: missing={sorted(listed - actual)}, extra={sorted(actual - listed)}")
    for name, expected in manifest["files"].items():
        raw = (ROOT / name).read_bytes()
        if {"bytes": len(raw), "sha256": digest(raw)} != expected:
            raise ValueError(f"Checksum mismatch: {name}")
        if name.startswith("snapshots/") and SECRET.search(raw):
            raise ValueError(f"Potential secret in snapshot: {name}")
    long_book = (ROOT / SOURCES["rulin"]["output"]).read_bytes().decode("utf-8")
    if len(long_book) != 200_000:
        raise ValueError("Long Chinese sample must have exactly 200,000 Unicode code points")
    for label, expected_state in (("aq_complete", "done"), ("bovary_partial", "paused")):
        status = json.loads((ROOT / "snapshots" / label / "status.json").read_text())
        if status["state"] != expected_state or not 0 <= status["done"] <= status["total"]:
            raise ValueError(f"Invalid {label} snapshot state")
    base = ROOT / "snapshots/aq_complete"
    annotated = ROOT / "snapshots/aq_annotated"
    base_files = {str(p.relative_to(base)): p.read_bytes() for p in base.rglob("*") if p.is_file()}
    annotated_files = {str(p.relative_to(annotated)): p.read_bytes() for p in annotated.rglob("*") if p.is_file()}
    if annotated_files.keys() != base_files.keys() | {"notebook.json"}:
        raise ValueError("Annotated 阿Q snapshot file set differs from its base")
    if any(annotated_files[name] != raw for name, raw in base_files.items()):
        raise ValueError("Annotated 阿Q snapshot changed the public-domain base")
    notes = json.loads(annotated_files["notebook.json"])
    if len(notes) != 1 or notes[0].get("revision") != 1:
        raise ValueError("Annotated 阿Q snapshot must contain one API-created note")
    for name in ("aq", "jekyll", "rulin", "french"):
        if b"Project Gutenberg" in (ROOT / SOURCES[name]["output"]).read_bytes():
            raise ValueError(f"eBook wrapper remains in {name}")
    print(f"Verified {len(actual)} corpus files ({sum(x['bytes'] for x in manifest['files'].values())} bytes)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true", help="check all shipped files without network or writes")
    parser.add_argument("--source-dir", type=Path, help="directory holding the five pinned upstream downloads")
    parser.add_argument("--snapshot-root", type=Path, help="capture two public-domain books from a local 1.7.x library")
    args = parser.parse_args()
    if args.verify:
        verify()
        return
    books(args.source_dir)
    synthetic()
    if args.snapshot_root:
        capture_snapshots(args.snapshot_root)
    make_api_annotated_snapshot(force=args.snapshot_root is not None)
    write_manifest()
    verify()


if __name__ == "__main__":
    main()
