# xwiki2obsidian

A Bash script to convert XWiki HTML exports into an Obsidian-compatible Markdown vault.

Developed and tested against XWiki with the **Flamingo/Iceberg theme**. Results may vary for other themes or versions.

---

## Features

- Extracts only page content (`#xwikicontent`), stripping all XWiki navigation/UI
- Converts XWiki code blocks (`<div class="box"><div class="code">`) to fenced ` ``` ` blocks
- Preserves `<br/>`-separated lines inside code blocks
- Rewrites image links to Obsidian wikilink syntax: `![[Note name/file.png]]`
- Rewrites attachment links: `[[Note name/file.rsc|label]]`
- Copies attachments into per-note subfolders
- Decodes URL-encoded note names (`Tron+settings` → `Tron settings.md`)
- Removes XWiki navigation artifacts: empty divs, `<!-- -->` separators, `wikimodel-*` classes
- Unwraps XWiki syntax-highlighter spans (every word wrapped in styled `<span>`)
- Unescapes characters pandoc unnecessarily escapes in GFM: `` ` ``, `[`, `]`, `*`
- Merges adjacent fenced code blocks split across multiple XWiki boxes
- Preserves category structure as Obsidian folders

---

## Requirements

| Tool | Install |
|------|---------|
| `pandoc` | `apt install pandoc` |
| `python3` | usually pre-installed |
| `python3-bs4` | `apt install python3-bs4` or `pip3 install beautifulsoup4` |

---

## Step 1 — Export HTML from XWiki

Run this command against your XWiki instance to download the full HTML export as a ZIP:

```bash
curl -s "http://user:password@wiki.url/bin/export/Space/Page?basicauth=1&format=html&pages=Main.%" \
  --output "./xwiki_html_backup.zip"
```

Then unpack it:

```bash
unzip xwiki_html_backup.zip -d ~/xwiki-export
```

Expected structure after unpacking:

```
xwiki-export/
├── pages/
│   └── xwiki/
│       └── Main/
│           ├── Crypto/
│           │   └── Tron+settings/
│           │       └── WebHome.html
│           └── ...
└── attachment/
    └── xwiki/
        └── Main/
            ├── Crypto/
            │   └── Tron+settings/
            │       └── WebHome/
            │           └── file.png
            └── ...
```

---

## Step 2 — Run the converter

```bash
chmod +x xwiki2obsidian.sh

# Using default paths:
./xwiki2obsidian.sh

# Or specify paths explicitly:
./xwiki2obsidian.sh \
  ./xwiki-export/pages/xwiki/Main \
  ./xwiki-export/attachment/xwiki/Main \
  ./obsidian-vault
```

---

## Output structure

```
obsidian-vault/
├── Crypto/
│   ├── Tron settings.md
│   └── Tron settings/
│       ├── image1.png
│       └── file.rsc
├── Development/
│   └── ...
└── ...
```

---

## Known limitations

- **Plain-text code blocks**: If code was pasted into XWiki as a plain paragraph (no `<div class="box">`), it will not be wrapped in a fenced code block. This is a limitation of the source data, not the converter.
- **Theme dependency**: Tested against XWiki Flamingo/Iceberg theme HTML export. Other themes may use different HTML structures.
- **Single-level nesting**: The script handles one level of categories (`Main/Category/NoteName`). Deeper nesting is not currently supported.

---

## License

MIT
