# Contributing

Thanks for helping. A few things keep this project honest:

1. **No new runtime dependencies** for the server or pipeline. Everything runs on the Python standard
   library so `python3 -m server.app` works on a clean machine. The web interface has no framework and
   no build step.
2. **Spoilers are the bug that matters.** If you change extraction, merging or the judge and claim it
   is better, write spoiler probes first (see `testsets/*/probes.json` and `tests/spoiler_probes_v3.py`),
   then run, and report the leaks you found by hand — not only a score.
3. **Keep test and development books apart.** Once you have looked at individual cases in a book to
   tune something, it is a development book, not a test book.
4. **Always report the majority-class baseline** for any judge or classifier accuracy.
5. **Don't commit book text.** Probes and code only; `data/` is ignored on purpose.

## Checks before a pull request

```bash
python3 -m unittest discover -s tests -p 'test*.py'
for f in tests/*.test.mjs; do node "$f"; done
python3 scripts/check_i18n.py          # if you touched interface strings
```

Interface strings are written in Chinese in the source and translated in `web/js/locales/*.js`;
`scripts/check_i18n.py` checks every catalog covers every key. Corrections to the translations are
very welcome.
