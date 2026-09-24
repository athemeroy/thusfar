"""Time-travel check: the same person's card at two different pages.

Jumps with the TOC page box to page A, opens the most prominent person in the cast list,
records the card text; then page B (later) and back to A. The card at A must be identical
before and after visiting B, and must not contain anything that only appears at B.

usage: PASSCODE=... python tests/time_travel.py BASE BOOK PAGE_A PAGE_B OUTDIR
"""
import asyncio
import os
import sys
from pathlib import Path
from playwright.async_api import async_playwright

BASE, BOOK, A, B = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
OUT = Path(sys.argv[5] if len(sys.argv) > 5 else 'shots')
OUT.mkdir(parents=True, exist_ok=True)


async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(args=['--no-proxy-server'])
        ctx = await b.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, has_touch=True)
        page = await ctx.new_page()
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        await page.goto(BASE + '/#/')
        await page.wait_for_timeout(1000)
        if os.environ.get('PASSCODE') and await page.is_visible('.login input'):
            await page.fill('.login input', os.environ['PASSCODE'])
            await page.click('.login button')
            await page.wait_for_timeout(1200)
        await page.goto(BASE + f'/#/read/{BOOK}')
        await page.wait_for_timeout(3500)

        async def chrome():
            if not await page.evaluate('document.querySelector(".reader").classList.contains("ui")'):
                await page.mouse.click(195, 420)
                await page.wait_for_timeout(350)

        async def jump(n):
            await chrome()
            await page.click('.dock button:has-text("目录")')
            await page.wait_for_timeout(600)
            await page.fill('.jump input', str(n))
            await page.click('.jump .btn')
            await page.wait_for_timeout(1800)

        async def card(tag, who=None):
            await chrome()
            await page.click('.dock button:has-text("人物")')
            await page.wait_for_timeout(800)
            await page.click('.seg-ctl button:has-text("全部")')   # the list opens on "本页" by default
            await page.wait_for_timeout(300)
            rows = page.locator('.cast-row')
            if who:
                rows = rows.filter(has_text=who)
            name = await rows.first.locator('.n').evaluate('e => e.firstChild.textContent')
            await rows.first.click()
            await page.wait_for_timeout(900)
            await page.evaluate('document.querySelector(".sheet").classList.add("full")')
            await page.wait_for_timeout(450)
            await page.screenshot(path=OUT / f'tt-{tag}.png')
            text = await page.inner_text('.sheet .pane')
            await page.mouse.click(195, 20)
            await page.wait_for_timeout(500)
            return name.split('\n')[0], text

        await jump(A)
        who, a1 = await card(f'A{A}')
        await jump(B)
        _, b1 = await card(f'B{B}', who)
        await jump(A)
        _, a2 = await card(f'A{A}-again', who)
        folio = await page.evaluate('document.querySelector(".folio").textContent')
        print('person:', who, '| folio after return:', folio)
        print('card at A identical before/after visiting B:', a1.replace('\n', '') == a2.replace('\n', ''))
        la, lb = set(a1.split('\n')), set(b1.split('\n'))
        print(f'lines only at B ({len(lb - la)}):', [x for x in lb - la if len(x) > 6][:8])
        print('errors:', errors or 'none')
        await b.close()

asyncio.run(main())
