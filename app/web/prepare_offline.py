"""Version the built offline service worker after `flutter build web`.

Flutter copies app/web into build/web, then generates the release bundle. This
step gives the worker a content-derived cache name so a Pages update installs
new shell files atomically. It only edits the built worker, never book data.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


CORE_PATHS = (
    "index.html",
    "flutter_bootstrap.js",
    "flutter.js",
    "main.dart.js",
    "manifest.json",
    "favicon.png",
    "icons/Icon-128.png",
    "icons/Icon-512.png",
    "assets/AssetManifest.bin",
    "assets/AssetManifest.bin.json",
    "assets/FontManifest.json",
    "assets/fonts/MaterialIcons-Regular.otf",
    "assets/assets/fonts/NotoSerifSC-Regular.otf",
    "assets/assets/fonts/NotoSansSC.ttf",
    "assets/assets/fonts/OFL-NotoSansSC.txt",
    "assets/assets/fonts/ZCOOLXiaoWei-Regular.ttf",
    "assets/assets/fonts/LXGWWenKaiScreen.ttf",
    "assets/assets/fonts/OFL-LXGWWenKaiScreen.txt",
    "assets/shaders/stretch_effect.frag",
    "assets/shaders/ink_sparkle.frag",
    "canvaskit/canvaskit.js",
    "canvaskit/canvaskit.wasm",
    "canvaskit/chromium/canvaskit.js",
    "canvaskit/chromium/canvaskit.wasm",
)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: prepare_offline.py BUILD_WEB_DIR")
    root = Path(sys.argv[1]).resolve(strict=True)
    worker = root / "app_shell_sw.js"
    source = worker.read_text(encoding="utf-8")
    marker = "const BUILD_ID = 'unprepared';"
    if source.count(marker) != 1:
        raise SystemExit("offline worker build marker missing or repeated")

    digest = hashlib.sha256()
    total_bytes = 0
    for name in CORE_PATHS:
        asset = root / name
        if not asset.is_file():
            raise SystemExit(f"offline core asset missing: {name}")
        digest.update(name.encode("utf-8"))
        with asset.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
                total_bytes += len(chunk)
    build_id = digest.hexdigest()[:20]
    worker.write_text(
        source.replace(marker, f"const BUILD_ID = '{build_id}';"),
        encoding="utf-8",
    )
    # The helper is copied by Flutter from app/web; it is not a web asset.
    (root / "prepare_offline.py").unlink(missing_ok=True)
    print(f"Offline shell {build_id}: {len(CORE_PATHS)} files, {total_bytes} bytes")


if __name__ == "__main__":
    main()
