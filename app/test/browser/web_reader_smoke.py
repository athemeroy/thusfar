"""Exercise the released Flutter browser UI using real file-picker imports.

Build lib/main_web.dart, run prepare_offline.py, and serve that build first.
Use a fresh browser context for every viewport so no personal library is read.
The only fixture publication is the user's file-picker workflow; this script
never writes IndexedDB, localStorage, or model credentials through JavaScript.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import time
import struct
import zipfile
import zlib
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import expect, sync_playwright


def fixture(title: str) -> bytes:
    paragraphs = []
    for chapter in range(1, 4):
        paragraphs.append(f"第{chapter}章 林间的来信")
        for index in range(48):
            paragraphs.append(
                f"林远把第{index + 1}封来信放在桌上。清晨的风经过窗边，"
                "他沿着熟悉的小路走向书房，读完一段，再记下自己的想法。"
                "远处传来脚步声，朋友带来一份地图，两人商量今天的行程。"
            )
    return (title + "\n\n" + "\n\n".join(paragraphs)).encode("utf-8")


def fixture_epub() -> bytes:
    """An original, minimal EPUB 2 with one verifiable local illustration."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))

    pixels = b"".join(b"\0" + bytes(channel for x in range(240)
        for channel in (52 + x * 72 // 239, 88 + y * 48 // 139, 74 + (x + y) % 25))
        for y in range(140))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", 240, 140, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))
    # The existing EPUB parser omits images <=1500 bytes as small decorations.
    # Use a genuine illustration above that threshold to exercise image storage.
    assert len(png) > 1500
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
</rootfiles></container>''')
        archive.writestr("OEBPS/content.opf", '''<?xml version="1.0" encoding="UTF-8"?>
<package version="2.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">thusfar-ui-fixture</dc:identifier>
<dc:title>跨端插图测试</dc:title><dc:creator>页读测试</dc:creator><dc:language>zh</dc:language></metadata>
<manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
<item id="image" href="illustration.png" media-type="image/png"/>
<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>
<spine toc="toc"><itemref idref="chapter"/></spine></package>''')
        archive.writestr("OEBPS/toc.ncx", '''<?xml version="1.0" encoding="UTF-8"?>
<ncx version="2005-1" xmlns="http://www.daisy.org/z3986/2005/ncx/"><head/>
<docTitle><text>跨端插图测试</text></docTitle><navMap><navPoint id="one" playOrder="1">
<navLabel><text>本地插图</text></navLabel><content src="chapter.xhtml"/>
</navPoint></navMap></ncx>''')
        archive.writestr("OEBPS/chapter.xhtml", '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>本地插图</title></head><body>
<h1>本地插图</h1><p>EPUB_FIXTURE_START 林远打开图册，绿色的插图随这本书一起保存在本地。</p>
<img src="illustration.png" alt="本地插图测试图" width="240" height="140"/>
<p>他合上窗户，在页边留下一个书签。这段原创测试文字没有来自真实的用户书库。</p>
</body></html>''')
        archive.writestr("OEBPS/illustration.png", png)
    return output.getvalue()


def enable_accessibility(page, expected_button: str = "导入书籍") -> None:
    # Flutter's public accessibility activation control is present before its
    # semantic tree. Activating it lets the checks use user-visible labels.
    if page.get_by_role("button", name=expected_button, exact=True).count():
        return
    page.wait_for_function("document.querySelector('flt-semantics-placeholder') || "
        "document.querySelector('flt-semantics [role=button]')")
    placeholder = page.locator("flt-semantics-placeholder")
    if placeholder.count():
        placeholder.dispatch_event("click")
    expect(page.get_by_role("button", name=expected_button, exact=True)).to_be_visible()


def import_book(page, title: str) -> None:
    with page.expect_file_chooser() as pending:
        click_button(page, "导入书籍")
    pending.value.set_files(
        {"name": title + ".txt", "mimeType": "text/plain", "buffer": fixture(title)}
    )
    expect(page.get_by_role("button", name="开始阅读", exact=True)).to_be_enabled()


def button(page, name: str):
    return page.get_by_role("button", name=name, exact=True)


def shelf_card(page, title: str):
    return page.get_by_role("progressbar", name=re.compile(re.escape(title)))


def reveal_shelf_control(page, control, name: str, *, below: bool,
                         book_title: str | None = None):
    if control.count():
        return control
    # A short landscape viewport can omit a card's offscreen buttons from
    # Flutter's semantic tree. Confirm the actual shelf card first; this
    # deliberate library scroll is separate from waiting for a new sheet.
    marker = shelf_card(page, book_title) if book_title else page.get_by_role(
        "progressbar", name=re.compile("多端体验测试|夜航记录|跨端插图测试"))
    expect(marker.first).to_be_attached()
    viewport = page.viewport_size
    for _ in range(24):
        if control.count():
            return control
        page.mouse.move(viewport["width"] / 2, viewport["height"] * 0.65)
        page.mouse.wheel(0, 200 if below else -200)
        print(json.dumps({"shelf_reveal": name,
                          "wheel_y": 200 if below else -200}, ensure_ascii=False), flush=True)
        page.evaluate("() => new Promise(resolve => "
            "requestAnimationFrame(() => requestAnimationFrame(resolve)))")
    expect(control).to_be_attached()
    return control


def shelf_search_field(page):
    return reveal_shelf_control(page, page.get_by_role(
        "textbox", name="搜索书名或作者", exact=True), "搜索书名或作者", below=False)


def shelf_header_button(page, name: str):
    return reveal_shelf_control(page, button(page, name), name, below=False)


def shelf_book_options(page, title: str):
    name = f"《{title}》书籍选项"
    return reveal_shelf_control(page, button(page, name), name,
                                below=True, book_title=title)


def dismiss(page, name: str) -> None:
    click_button(page, name)
    # Wait for the rendered semantic node to disappear, including the sheet's
    # dismissal animation, before focusing a field on the underlying route.
    expect(button(page, name)).to_have_count(0)


def click_semantic_bounds(page, control, name: str) -> dict[str, float]:
    # Wait for Flutter to publish the target before interpreting missing
    # geometry as an offscreen item. Scrolling while a new sheet is mounting
    # can move its controls away before their first semantic frame.
    expect(control).to_be_attached()
    expect(control).to_be_enabled()
    # Native DOM scrolling can move a Flutter semantic proxy independently of
    # its Canvas scroll view. Reveal offscreen controls with a real wheel over
    # the visible sheet or library instead, then read the updated screen bounds.
    previous = None
    stable_frames = 0
    for _ in range(120):
        geometry = control.evaluate("""el => {
          const r = el.getBoundingClientRect();
          const clip = {left:0, top:0, right:innerWidth, bottom:innerHeight};
          for (let p = el.parentElement; p; p = p.parentElement) {
            const s = getComputedStyle(p), b = p.getBoundingClientRect();
            if (['hidden','clip','auto','scroll'].includes(s.overflowY)) {
              clip.top = Math.max(clip.top, b.top);
              clip.bottom = Math.min(clip.bottom, b.bottom);
            }
            if (['hidden','clip','auto','scroll'].includes(s.overflowX)) {
              clip.left = Math.max(clip.left, b.left);
              clip.right = Math.min(clip.right, b.right);
            }
          }
          return {bounds:{x:r.x,y:r.y,width:r.width,height:r.height}, clip,
            editable:el.matches('input,textarea,[contenteditable=true]')};
        }""")
        bounds, clip = geometry["bounds"], geometry["clip"]
        unchanged = previous is not None and all(
            abs(bounds[key] - previous["bounds"][key]) < 0.01
            for key in ("x", "y", "width", "height")) and all(
            abs(clip[key] - previous["clip"][key]) < 0.01
            for key in ("left", "top", "right", "bottom"))
        stable_frames = stable_frames + 1 if unchanged else 0
        previous = geometry
        # A sheet's incoming animation can initially place its scrollport
        # outside the screen. Let that geometry settle before sending a wheel.
        if stable_frames < 2:
            page.evaluate("() => new Promise(resolve => requestAnimationFrame(resolve))")
            continue
        editable = geometry["editable"]
        clipped_top = not editable and bounds["height"] < 43.9 and abs(bounds["y"] - clip["top"]) < 0.1
        clipped_bottom = not editable and bounds["height"] < 43.9 and abs(bounds["y"] + bounds["height"] - clip["bottom"]) < 0.1
        # Flutter's editing proxy can extend horizontally beyond the painted
        # TextField. Focus its visible intersection; button and option targets
        # must have their whole rectangle available.
        horizontal_visible = editable or (bounds["x"] >= clip["left"] - 0.1
            and bounds["x"] + bounds["width"] <= clip["right"] + 0.1)
        fully_visible = (bounds["width"] > 0 and bounds["height"] > 0
            and horizontal_visible and not clipped_top and not clipped_bottom
            and bounds["y"] >= clip["top"] - 0.1
            and bounds["y"] + bounds["height"] <= clip["bottom"] + 0.1)
        if not fully_visible:
            previous, stable_frames = None, 0
            if clipped_top:
                delta = -(44 - bounds["height"] + 8)
            elif clipped_bottom:
                delta = 44 - bounds["height"] + 8
            elif bounds["y"] < clip["top"]:
                delta = -min(250, clip["top"] - bounds["y"] + 8)
            else:
                delta = min(250, bounds["y"] + bounds["height"] - clip["bottom"] + 8)
            assert clip["bottom"] > clip["top"], f"Control {name} has no visible scrollport"
            page.mouse.move((clip["left"] + clip["right"]) / 2,
                            (clip["top"] + clip["bottom"]) / 2)
            page.mouse.wheel(0, delta)
            page.evaluate("() => new Promise(resolve => "
                "requestAnimationFrame(() => requestAnimationFrame(resolve)))")
            continue
        break
    else:
        raise AssertionError(f"Control {name} has no stable fully visible bounds: {geometry}")
    expect(control).to_be_visible()
    # Flutter's transparent route and sheet semantics layers sit above some
    # proxies in the DOM. Physical clicks still reach the Canvas controls, as
    # verified by elementFromPoint, real clicks, and the current SDK source.
    # Use that visible control's actual screen bounds, without force or DOM
    # mutation. Each caller checks the user-visible result of that action.
    left = max(bounds["x"], clip["left"])
    right = min(bounds["x"] + bounds["width"], clip["right"])
    x, y = (left + right) / 2, bounds["y"] + bounds["height"] / 2
    print(json.dumps({"physical_action": name, "x": x, "y": y,
                      "bounds": bounds, "visible_clip": clip}, ensure_ascii=False), flush=True)
    page.mouse.click(x, y)
    return {"width": bounds["width"], "height": bounds["height"]}


def click_button(page, name: str) -> dict[str, float]:
    return click_semantic_bounds(page, button(page, name), name)


def choose_option(page, name: str) -> dict[str, float]:
    control = page.get_by_role("checkbox", name=name, exact=True)
    bounds = click_semantic_bounds(page, control, name)
    expect(control).to_be_checked()
    assert bounds["width"] >= 43.9 and bounds["height"] >= 43.9, f"Option {name} needs a 44px touch target: {bounds}"
    return bounds


def open_reader_tools(page) -> dict[str, float]:
    bounds = click_button(page, "打开阅读工具")
    assert bounds["width"] >= 43.9 and bounds["height"] >= 43.9, "Reading tools need a 44px touch target"
    expect(button(page, "收起工具")).to_be_visible()
    return bounds


def focus_text_field(page, field) -> None:
    # Flutter first transfers focus from its semantics proxy to the active
    # editing element. Use real browser typing after that focus transfer.
    label = field.get_attribute("aria-label")
    click_semantic_bounds(page, field, label or "text field")
    expect(field).to_be_focused()
    page.wait_for_function("label => { const a = document.activeElement; "
        "return a && a.matches('input,textarea,[contenteditable=true]') && "
        "(a.closest('flt-text-editing-host') || a.getAttribute('aria-label') === label); }",
        arg=label)
    # Flutter connects the focused semantic editor on its next frame. Wait for
    # that frame and the following paint instead of racing the focus bridge.
    page.evaluate("() => new Promise(resolve => "
        "requestAnimationFrame(() => requestAnimationFrame(resolve)))")


def enter_text(page, field, text: str) -> None:
    focus_text_field(page, field)
    page.keyboard.press("ControlOrMeta+A")
    page.keyboard.press("Backspace")
    if text:
        page.keyboard.type(text, delay=35)
    expect(field).to_have_value(text)


def progress(page) -> str:
    return page.get_by_text(re.compile(r"^\d+(?:\.\d+)?%$")).first.inner_text()


def reader_body(page):
    # Flutter exposes the rendered selectable page as a tappable semantic
    # group. Its text distinguishes a chapter boundary even when the rounded
    # global percentage is equal on both sides of that boundary.
    return page.locator("flt-semantics[role='group'][flt-tappable][aria-label]").first


def reading_signature(page) -> tuple[str, str, str]:
    heading = page.get_by_text(re.compile(r"^(开始|封面|多端体验测试|第[123]章 林间的来信)$")).first.inner_text()
    return heading, progress(page), reader_body(page).get_attribute("aria-label")


def expect_reading_signature(page, signature: tuple[str, str, str]) -> None:
    heading, percent, body = signature
    expect(page.get_by_text(heading, exact=True).first).to_be_visible()
    expect(page.get_by_text(re.compile(r"^\d+(?:\.\d+)?%$")).first).to_have_text(percent)
    expect(reader_body(page)).to_have_attribute("aria-label", body)


def capture_settled(page, path: Path) -> None:
    # The semantic tree can remove exiting controls before Canvas has finished
    # painting their animation. Wait for three equal, frame-separated real
    # screenshots so evidence shows the settled UI without changing the app.
    previous = None
    identical = 0
    for _ in range(30):
        captured = page.screenshot()
        identical = identical + 1 if captured == previous else 0
        if identical >= 2:
            path.write_bytes(captured)
            return
        previous = captured
        page.evaluate("() => new Promise(resolve => "
            "requestAnimationFrame(() => requestAnimationFrame(resolve)))")
    raise AssertionError(f"Canvas did not settle for screenshot {path.name}")


def expect_epub_text(page) -> None:
    # Flutter merges text into a group's accessible label on text-only pages;
    # an image splits it into rendered text, image, and text semantic nodes.
    marker_label = page.locator("flt-semantics[aria-label*='EPUB_FIXTURE_START']")
    marker_text = page.get_by_text(re.compile("EPUB_FIXTURE_START"))
    expect(marker_label.or_(marker_text).first).to_be_visible()


def run_viewport(browser, args, width: int, height: int, receipt: dict) -> None:
    context = browser.new_context(viewport={"width": width, "height": height})
    page = context.new_page()
    page.set_default_timeout(20000)
    errors = []
    console_failures = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.on("console", lambda message: console_failures.append(message.text)
            if "RenderFlex overflowed" in message.text or "EXCEPTION CAUGHT" in message.text
            else None)
    origin = urlsplit(args.url)
    model_requests = []
    blocked_font_requests = []
    option_bounds = {}

    def route(request_route):
        request = request_route.request
        target = urlsplit(request.url)
        if target.scheme in {"http", "https"} and target.netloc != origin.netloc:
            if target.hostname == "fonts.gstatic.com":
                blocked_font_requests.append(request.url)
            else:
                model_requests.append(request.url)
            request_route.abort()
        else:
            request_route.continue_()

    context.route("**/*", route)
    try:
        page.goto(args.url, wait_until="networkidle")
        enable_accessibility(page)
        import_book(page, "多端体验测试")
        dismiss(page, "收起提示")
        import_book(page, "夜航记录")
        dismiss(page, "收起提示")

        search = shelf_search_field(page)
        enter_text(page, search, "多端")
        expect(shelf_card(page, "多端体验测试")).to_be_attached()
        expect(shelf_card(page, "夜航记录")).to_have_count(0)
        click_button(page, "清空书架搜索")
        expect(search).to_have_value("")
        expect(shelf_card(page, "夜航记录")).to_be_attached()

        option_bounds["在读"] = choose_option(page, "在读")
        expect(button(page, "显示全部书籍")).to_be_visible()
        click_button(page, "显示全部书籍")
        click_semantic_bounds(page, shelf_book_options(page, "多端体验测试"), "《多端体验测试》书籍选项")
        expect(button(page, "关闭书籍选项")).to_be_visible()
        dismiss(page, "关闭书籍选项")
        capture_settled(page, args.out_dir / f"{width}x{height}-shelf.png")

        # With the shelf query there is exactly one visible continue action.
        enter_text(page, shelf_search_field(page), "多端")
        expect(shelf_card(page, "夜航记录")).to_have_count(0)
        reveal_shelf_control(page, button(page, "继续阅读"), "继续阅读",
                             below=True, book_title="多端体验测试")
        click_button(page, "继续阅读")
        expect(button(page, "打开阅读工具")).to_be_visible()
        before = reading_signature(page)
        page.keyboard.press("Control+ArrowRight")
        page.wait_for_timeout(100)
        assert reading_signature(page) == before, "Control+ArrowRight changed the reading position"
        page.keyboard.down("Control")
        try:
            page.mouse.move(width / 2, height / 2)
            page.mouse.wheel(0, 150)
        finally:
            page.keyboard.up("Control")
        page.wait_for_timeout(100)
        assert reading_signature(page) == before, "Control+wheel changed the reading position"
        page.keyboard.press("ArrowRight")
        # AnimatedSwitcher briefly exposes both pages as one semantic label.
        # Wait until the outgoing page text has left that rendered tree before
        # recording the position used for Back/Forward and reload comparisons.
        expect(reader_body(page)).not_to_have_attribute("aria-label", re.compile(re.escape(before[2])))

        expect(page).to_have_url(re.compile(r"#/read/[0-9a-f]{24}$"))
        reader_url = page.url
        saved_position = reading_signature(page)
        page.go_back(wait_until="networkidle")
        expect(shelf_header_button(page, "导入书籍")).to_be_visible()
        search = shelf_search_field(page)
        focus_text_field(page, search)
        expect(search).to_have_value("多端")
        expect(shelf_card(page, "夜航记录")).to_have_count(0)
        page.go_forward(wait_until="networkidle")
        expect(button(page, "打开阅读工具")).to_be_visible()
        assert page.url == reader_url, "Browser Forward did not restore the book URL"
        expect_reading_signature(page, saved_position)
        page.reload(wait_until="networkidle")
        enable_accessibility(page, "打开阅读工具")
        expect_reading_signature(page, saved_position)

        tools_bounds = open_reader_tools(page)
        before = progress(page)
        page.mouse.move(width / 2, height - 40)
        page.mouse.wheel(0, 150)
        page.wait_for_timeout(450)
        assert progress(page) == before, "Scrolling the toolbar changed the reading position"
        click_button(page, "目录")
        expect(button(page, "关闭目录")).to_be_visible()
        dismiss(page, "关闭目录")
        click_button(page, "搜索")
        expect(button(page, "关闭搜索")).to_be_visible()
        body_search = page.get_by_role("textbox", name="搜索读到这里的正文", exact=True)
        enter_text(page, body_search, "林远")
        click_button(page, "清空正文搜索")
        expect(body_search).to_have_value("")
        capture_settled(page, args.out_dir / f"{width}x{height}-search.png")
        dismiss(page, "关闭搜索")

        click_button(page, "排版")
        expect(button(page, "关闭阅读排版")).to_be_visible()
        option_bounds["连续滚动"] = choose_option(page, "连续滚动")
        capture_settled(page, args.out_dir / f"{width}x{height}-typography.png")
        dismiss(page, "关闭阅读排版")
        dismiss(page, "收起工具")
        before_scroll = progress(page)
        page.mouse.move(width / 2, height / 2)
        page.mouse.wheel(0, 500)
        scroll_started = time.perf_counter()
        expect(page.get_by_text(re.compile(r"^\d+(?:\.\d+)?%$")).first).not_to_have_text(before_scroll)
        scroll_position = progress(page)
        scroll_heading = page.get_by_text(re.compile(r"^(开始|封面|多端体验测试|第[123]章 林间的来信)$")).first.inner_text()
        scroll_back_delay_ms = round((time.perf_counter() - scroll_started) * 1000)
        assert scroll_back_delay_ms < 500, "Scroll check missed the pending 500 ms save debounce"
        page.go_back(wait_until="networkidle")
        expect(shelf_header_button(page, "导入书籍")).to_be_visible()
        page.go_forward(wait_until="networkidle")
        expect(button(page, "打开阅读工具")).to_be_visible()
        expect(page.get_by_text(re.compile(r"^\d+(?:\.\d+)?%$")).first).to_have_text(scroll_position)
        expect(page.get_by_text(scroll_heading, exact=True).first).to_be_visible()
        open_reader_tools(page)
        click_button(page, "返回书架")
        expect(shelf_header_button(page, "导入书籍")).to_be_visible()
        search = shelf_search_field(page)
        expect(search).to_have_value("")
        enter_text(page, search, "")
        page.reload(wait_until="networkidle")
        enable_accessibility(page)
        expect(shelf_card(page, "多端体验测试")).to_be_attached()

        # A completed service-worker shell must reopen the real imported book
        # while disconnected. Waiting is bounded; an absent shell is a failure.
        page.wait_for_function("Boolean(navigator.serviceWorker.controller)")
        context.set_offline(True)
        page.reload(wait_until="domcontentloaded")
        enable_accessibility(page)
        expect(page.get_by_text(re.compile(r"^当前离线"))).to_be_visible()
        enter_text(page, shelf_search_field(page), "多端")
        expect(shelf_card(page, "夜航记录")).to_have_count(0)
        reveal_shelf_control(page, button(page, "继续阅读"), "继续阅读",
                             below=True, book_title="多端体验测试")
        click_button(page, "继续阅读")
        expect(button(page, "打开阅读工具")).to_be_visible()
        open_reader_tools(page)
        click_button(page, "排版")
        # Kai has not been selected online in this context. Its first use must
        # work from the completed offline app shell, not an online font cache.
        option_bounds["楷体"] = choose_option(page, "楷体")
        dismiss(page, "关闭阅读排版")
        dismiss(page, "收起工具")
        capture_settled(page, args.out_dir / f"{width}x{height}-offline-reader.png")
        open_reader_tools(page)
        click_button(page, "排版")
        option_bounds["黑体"] = choose_option(page, "黑体")
        dismiss(page, "关闭阅读排版")
        dismiss(page, "收起工具")
        capture_settled(page, args.out_dir / f"{width}x{height}-offline-sans-reader.png")

        epub_checked = width == 390 and height == 844
        if epub_checked:
            context.set_offline(False)
            open_reader_tools(page)
            dismiss(page, "返回书架")
            with page.expect_file_chooser() as pending:
                click_button(page, "导入书籍")
            pending.value.set_files({"name": "跨端插图测试.epub",
                "mimeType": "application/epub+zip", "buffer": fixture_epub()})
            expect(button(page, "开始阅读")).to_be_enabled()
            click_button(page, "开始阅读")
            expect(button(page, "打开阅读工具")).to_be_visible()
            expect(page.get_by_role("img", name="本地插图测试图", exact=True)).to_be_visible()
            expect_epub_text(page)
            capture_settled(page, args.out_dir / "390x844-epub-reader.png")
            epub_url = page.url
            page.reload(wait_until="networkidle")
            enable_accessibility(page, "打开阅读工具")
            assert page.url == epub_url
            expect(page.get_by_role("img", name="本地插图测试图", exact=True)).to_be_visible()
            context.set_offline(True)
            page.reload(wait_until="domcontentloaded")
            enable_accessibility(page, "打开阅读工具")
            expect(page.get_by_role("img", name="本地插图测试图", exact=True)).to_be_visible()
            expect_epub_text(page)
            capture_settled(page, args.out_dir / "390x844-epub-offline.png")
        assert not errors, errors
        assert not console_failures, console_failures
        assert not model_requests, "Local reading attempted an external network request"
        receipt["viewports"].append({"width": width, "height": height,
            "status": "passed", "blocked_renderer_font_requests": len(blocked_font_requests),
            "control_actions": "real mouse clicks at stable rendered role-button and option bounds; visible results and selection checked",
            "reader_tools_bounds": tools_bounds,
            "reader_option_bounds": option_bounds,
            "scroll_back_delay_ms": scroll_back_delay_ms,
            "epub_with_local_png_checked": epub_checked,
            "checks": ["real TXT file-picker import", "search and filters",
            "scrollable book menu", "modifier-safe reading", "reader URL and reload",
            "browser Back and Forward", "toolbar wheel isolation",
            "explicit sheet close", "search clear", "typography mode switch", "continuous scroll Back flush",
            "local library reload", "offline reopen", "first Kai selection offline", "Sans body selection offline", "no model requests"]})
    except Exception as failure:
        page.screenshot(path=str(args.out_dir / f"{width}x{height}-failure.png"))
        (args.out_dir / f"{width}x{height}-failure-dom.html").write_text(page.content())
        receipt["viewports"].append({"width": width, "height": height,
            "status": "failed", "error": str(failure), "page_errors": errors,
            "console_failures": console_failures,
            "external_requests": [urlsplit(url)._replace(query="", fragment="").geturl()
                for url in [*model_requests, *blocked_font_requests]]})
        raise
    finally:
        context.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", "--base-url", dest="url", required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--cdp", help="Use an existing isolated Chrome endpoint")
    parser.add_argument("--browser-executable", default=os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH"))
    parser.add_argument("--viewport", action="append", help="WIDTHxHEIGHT; default covers phone/tablet/desktop")
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    sizes = args.viewport or ["320x568", "390x844", "640x360", "768x1024", "1440x900"]
    receipt = {"url": args.url, "fixture": "authored fictional TXT imported with a file chooser",
        "limitations": "Chromium smoke; actual mobile soft keyboard and assistive technology require device checks",
        "viewports": []}
    with sync_playwright() as playwright:
        browser = playwright.chromium.connect_over_cdp(args.cdp) if args.cdp else playwright.chromium.launch(
            headless=True, executable_path=args.browser_executable)
        try:
            for size in sizes:
                width, height = map(int, size.split("x"))
                run_viewport(browser, args, width, height, receipt)
        finally:
            (args.out_dir / "receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2))
            if not args.cdp:
                browser.close()
    print(json.dumps(receipt, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
