# MacRumors 投稿文(下書き・英語)

宛先: Aquafox スレッド、blackbirdlc 氏宛て

---

Subject: Japanese localization for Aquafox (built on the official Fx 45.9.0esr ja langpack)

Hi blackbirdlc,

I've put together a Japanese (ja) locale for Aquafox and wanted to share it here in case it's useful for upstream inclusion.

**What I did:**
- Started from Mozilla's official `ja` langpack for Firefox 45.9.0esr (same app ID, `maxVersion=45.*` already covers Aquafox's `45.43.1`, so no install.rdf changes were needed)
- Diffed every locale file (DTD entities and .properties keys) against Aquafox's own en-US strings to find what's missing — about 80 entries across 8 files were Aquafox/TenFourFox-specific additions not present in stock Firefox 45.9.0esr (reader mode toggle, media playback rate menu, the TenFourFox preferences pane strings, a few update-dialog strings, etc.)
- Translated those ~80 entries and merged them into the official ja langpack to produce a complete, self-contained `ja` locale for Aquafox

**Tested on:** iBook G4 (PowerBook6,5), Mac OS X 10.4.11, Aquafox 45.43.1 — installs as a sideloaded extension (`langpack-ja@firefox.mozilla.org.xpi`) in the profile's `extensions/` folder, no crashes, full UI in Japanese including the TenFourFox-specific preference panels.

I'd be glad to share the diff / patched xpi here, or open a PR if there's a repo you'd prefer patches against. Happy to also cover future string updates as Aquafox evolves, since the process (diff en-US against upstream Mozilla langpack) is now scripted and repeatable.

Let me know what format works best for you.

Thanks for maintaining Aquafox — it's the only realistic browser option left for G3/Tiger-only machines like the ones a lot of us are still running.

---

## 使い方メモ

- そのまま貼り付けてもOKですが、細部（口調・謙虚さの度合いなど）はご自身の言葉に直していただいて構いません
- 「repo があれば PR も可」の一文は、blackbirdlc 氏が GitHub 等でソース管理しているか分からないため、相手に判断を委ねる形にしています
- 実際に添付する場合は `ja-aquafox.xpi` を使ってください
