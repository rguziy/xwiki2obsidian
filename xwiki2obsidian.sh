#!/bin/bash

# =============================================================================
# xwiki2obsidian.sh — convert XWiki HTML export to Obsidian markdown vault
#
# Structure expected:
#   PAGES_DIR/Category/Note+Name/WebHome.html
#   ATTACHMENTS_DIR/Category/Note+Name/WebHome/<files>
#
# Output:
#   OUTPUT_DIR/Category/Note Name.md
#   OUTPUT_DIR/Category/Note Name/<attachments>
#
# Dependencies: pandoc, python3, python3-bs4
#
# Usage:
#   ./xwiki2obsidian.sh [pages_dir] [attachments_dir] [output_dir] [--flat-attachments]
#
# Options:
#   --flat-attachments   Copy all attachments into a single _attachments/ folder
#                        instead of per-note subfolders. Keeps the Obsidian file
#                        tree clean. Default: off (per-note subfolders).
# =============================================================================

set -euo pipefail

FLAT_ATTACHMENTS=false
POSITIONAL=()

# Separate flags from positional arguments
for arg in "$@"; do
    case "$arg" in
        --flat-attachments) FLAT_ATTACHMENTS=true ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

PAGES_DIR="${POSITIONAL[0]:-$HOME/xwiki-export/pages/xwiki/Main}"
ATTACHMENTS_DIR="${POSITIONAL[1]:-$HOME/xwiki-export/attachment/xwiki/Main}"
OUTPUT_DIR="${POSITIONAL[2]:-$HOME/obsidian-vault}"

# --- Dependency check ---
MISSING=0
for cmd in pandoc python3; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERR] Missing dependency: $cmd"; MISSING=1; }
done
python3 -c "import bs4" 2>/dev/null || {
    echo "[ERR] Missing Python library: bs4 (install with: apt install python3-bs4  OR  pip3 install beautifulsoup4)"
    MISSING=1
}
[ $MISSING -eq 1 ] && exit 1

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC} $1"; }

COUNT_OK=0
COUNT_ERR=0
COUNT_SKIP=0

# Python helper — extracts div#xwikicontent and cleans XWiki-specific HTML noise
EXTRACTOR=$(cat <<'PYEOF'
import sys
from bs4 import BeautifulSoup

html = sys.stdin.read()
soup = BeautifulSoup(html, 'html.parser')

content = soup.find(id='xwikicontent')
if not content:
    content = soup.find('body') or soup

# Unwrap single-cell tables — XWiki renders "info/note/warning" boxes as 1x1 tables
# Extract the cell content and replace the whole table with it
for table in content.find_all('table'):
    rows = table.find_all('tr')
    cells = table.find_all(['td', 'th'])
    if len(cells) == 1:
        # Single-cell table: just unwrap the content inline
        cell = cells[0]
        for child in reversed(list(cell.children)):
            table.insert_after(child.extract() if hasattr(child, 'extract') else child)
        table.decompose()

# Convert XWiki code blocks <div class="box"><div class="code"> → <pre><code>
# XWiki uses <br/> for line breaks inside code and <span> for syntax highlighting.
# We replace <br/> with newlines before extracting text, then strip the spans.
for box in content.find_all('div', class_='box'):
    code_div = box.find('div', class_='code')
    if code_div:
        # Replace <br> tags with newline markers before text extraction
        for br in code_div.find_all('br'):
            br.replace_with('\n')
        # Unwrap spans (syntax highlight wrappers) to get clean text
        for span in code_div.find_all('span'):
            span.unwrap()
        pre = soup.new_tag('pre')
        code = soup.new_tag('code')
        code.string = code_div.get_text()
        pre.append(code)
        box.replace_with(pre)

# Move <img> out of heading tags
for heading in content.find_all(['h1', 'h2', 'h3', 'h4', 'h5', 'h6']):
    imgs = heading.find_all('img')
    if imgs and not heading.get_text(strip=True):
        for img in imgs:
            heading.insert_before(img.extract())
        heading.decompose()
    elif imgs:
        for img in imgs:
            heading.insert_after(img.extract())

# Unwrap all <span> tags (XWiki syntax highlighter)
for span in content.find_all('span'):
    span.unwrap()

# Fix wikimodel-freestanding links
for a in content.find_all('a', class_='wikimodel-freestanding'):
    del a['class']
    href = a.get('href', '')
    if not a.get_text(strip=True):
        a.string = href

# Unwrap <div> inside <li> — XWiki wraps list item text in divs
# e.g. <li><div>text</div></li> → <li>text</li>
for li in content.find_all('li'):
    for div in li.find_all('div'):
        div.unwrap()

# Convert successmessage/infomessage/warningmessage boxes to blockquotes
for div in content.find_all('div', class_=lambda c: c and any(
        x in c for x in ['successmessage', 'infomessage', 'warningmessage', 'errormessage'])):
    bq = soup.new_tag('blockquote')
    bq.extend(div.contents[:])
    div.replace_with(bq)

# Remove empty wikimodel divs
for div in content.find_all('div', class_='wikimodel-emptyline'):
    div.decompose()

# Unwrap all remaining <div> tags — keeps content, removes wrapper
# Must be done last so special divs (box, successmessage) are handled first
for div in content.find_all('div'):
    div.unwrap()

print(content.decode_contents())
PYEOF
)

# Python helper — fixes image paths in the already-converted markdown:
#   pandoc converts <img src="../../../../attachment/.../WebHome/file.png"> to
#   ![file.png](../../../../attachment/.../WebHome/file.png)
#   We need: ![[Note name/file.png]]  (Obsidian wikilink embed syntax)
#
# Also handles any leftover raw <img> tags pandoc didn't convert.
IMG_FIXER=$(cat <<'PYEOF'
import sys, re, os
from bs4 import BeautifulSoup

note_name = sys.argv[1]
flat = len(sys.argv) > 2 and sys.argv[2] == "true"
attach_prefix = "_attachments" if flat else note_name
text = sys.stdin.read()

# Detect if a path points to a local XWiki attachment
# (relative path with ../ or contains /attachment/ or /WebHome/)
def is_local_attachment(path):
    return (
        path.startswith('../') or
        '/attachment/' in path or
        '/WebHome/' in path
    ) and not path.startswith('http')

# Fix markdown IMAGE links: ![alt](xwiki/path/file.png) → ![[note_name/file.png]]
def replace_md_img(m):
    alt, path = m.group(1), m.group(2)
    if is_local_attachment(path):
        fname = os.path.basename(path)
        return f'![[_attachments/{fname}]]'
    return m.group(0)  # external image — leave as-is

result = re.sub(r'!\[([^\]]*)\]\(([^)]+)\)', replace_md_img, text)

# Fix markdown NON-IMAGE links: [label](xwiki/path/file.ext) → [[note_name/file.ext|label]]
# These are file attachments (pdf, rsc, backup, zip, etc.)
def replace_md_link(m):
    label, path = m.group(1), m.group(2)
    if is_local_attachment(path):
        fname = os.path.basename(path)
        return f'[[{attach_prefix}/{fname}|{label}]]'
    return m.group(0)  # external link — leave as-is

result = re.sub(r'(?<!!)\[([^\]]+)\]\(([^)]+)\)', replace_md_link, result)

# Fix any leftover raw <img> tags pandoc didn't convert
def replace_raw_img(m):
    soup = BeautifulSoup(m.group(0), 'html.parser')
    img = soup.find('img')
    if not img:
        return m.group(0)
    src = img.get('src', '')
    fname = os.path.basename(src)
    return f'![[{attach_prefix}/{fname}]]'

result = re.sub(r'<img\s[^>]*/?>',  replace_raw_img, result, flags=re.DOTALL | re.IGNORECASE)

# Remove HTML comments (XWiki inserts <!-- --> as block separators)
result = re.sub(r'<!--.*?-->', '', result, flags=re.DOTALL)

# Merge adjacent fenced code blocks — XWiki sometimes splits one logical code block
# into multiple <div class="box"> blocks separated by whitespace/comments.
FENCE = chr(96) * 3
result = re.sub(FENCE + r'\n\n*' + FENCE + r'\n', '', result)

# Convert indented code blocks (4-space) to fenced ``` blocks
# Pandoc uses indented style for <pre> without class; Obsidian renders both,
# but fenced is cleaner and supports language hints
def indent_to_fence(m):
    lines = m.group(0).splitlines()
    # Strip the 4-space indent pandoc added
    code = '\n'.join(line[4:] if line.startswith('    ') else line for line in lines)
    return f'```\n{code.strip()}\n```'

result = re.sub(r'(?:^    .+\n?)+', indent_to_fence, result, flags=re.MULTILINE)

# Remove any remaining empty divs
result = re.sub(r'<div[^>]*>\s*</div>', '', result)

# Remove attachment links pointing to WebHome.html (XWiki self-referencing export artifact)
result = re.sub(r'\[\[[^\]]*WebHome\.html\|([^\]]*)\]\]', r'\1', result)
result = re.sub(r'\[\[[^\]]*WebHome\.html\]\]', '', result)

# Unescape characters pandoc unnecessarily escapes in GFM output:
#   \` → `   (backticks inside code)
#   \[ → [   (square brackets, e.g. [Interface] in config files)
#   \] → ]
#   \* → *   (asterisks used as wildcards, not markdown emphasis)
result = result.replace("\\`", "`")
result = result.replace("\\[", "[")
result = result.replace("\\]", "]")
result = result.replace("\\*", "*")

# Unescape ordered list numbers — pandoc escapes "0." → "0\."
# Match both at line start (actual lists) and inline (e.g. "2. **text**" in paragraphs)
result = re.sub(r"((?:^|\s)\d+)\\\.", r"\1.", result, flags=re.MULTILINE)

# Collapse 3+ blank lines → 2
result = re.sub(r'\n{3,}', '\n\n', result)

print(result, end='')
PYEOF
)

echo "========================================================"
echo " XWiki → Obsidian converter"
echo " Pages:       $PAGES_DIR"
echo " Attachments: $ATTACHMENTS_DIR"
echo " Output:      $OUTPUT_DIR"
echo "========================================================"

while IFS= read -r -d '' html_file; do

    note_dir=$(dirname "$html_file")

    # Skip WebHome.html files that sit directly inside PAGES_DIR or one level deep
    # (e.g. Main/WebHome.html or Main/Crypto/WebHome.html) — these are XWiki category
    # index pages auto-generated with a child page list, not real notes.
    rel_depth=$(echo "${note_dir#$PAGES_DIR/}" | tr -cd '/' | wc -c)
    if [ "$rel_depth" -lt 1 ]; then
        continue
    fi

    # Skip XWiki auto-generated category index pages — they contain a child page
    # list macro and no real content. Identified by the pagination widget text.
    content_text=$(python3 -c "
from bs4 import BeautifulSoup
import sys
try:
    soup = BeautifulSoup(open(sys.argv[1]).read(), 'html.parser')
    c = soup.find(id='xwikicontent')
    print(c.get_text(strip=True) if c else '')
except: pass
" "$html_file")
    if echo "$content_text" | grep -q "Click on one or more tags to filter the list"; then
        warn "skipping index page: ${note_dir#$PAGES_DIR/}"
        COUNT_SKIP=$((COUNT_SKIP + 1))
        continue
    fi

    # Build relative path from PAGES_DIR to note folder, decode each segment
    rel_path="${note_dir#$PAGES_DIR/}"
    decoded_path=$(python3 -c "
import sys, urllib.parse
parts = sys.argv[1].split('/')
decoded = [urllib.parse.unquote(p.replace('+', ' ')) for p in parts]
print('/'.join(decoded))
" "$rel_path")

    # Last segment is the note name, everything before is the folder hierarchy
    note_name=$(basename "$decoded_path")
    note_folder=$(dirname "$decoded_path")

    out_category_dir="$OUTPUT_DIR/$note_folder"
    out_md="$out_category_dir/${note_name}.md"
    if [ "$FLAT_ATTACHMENTS" = true ]; then
        out_assets_dir="$OUTPUT_DIR/_attachments"
    else
        out_assets_dir="$out_category_dir/${note_name}"
    fi

    mkdir -p "$out_category_dir"

    # --- Extract → clean → pandoc → fix image paths ---
    if ! python3 -c "$EXTRACTOR" < "$html_file" \
            | pandoc \
                --from=html \
                --to=gfm \
                --wrap=none \
                --strip-comments \
                --no-highlight \
                -o /dev/stdout 2>/dev/null \
            | python3 -c "$IMG_FIXER" "$note_name" "$FLAT_ATTACHMENTS" \
            > "$out_md"; then
        error "failed: $category/$note_name"
        COUNT_ERR=$((COUNT_ERR + 1))
        continue
    fi

    # --- Copy attachments ---
    attach_src="$ATTACHMENTS_DIR/$rel_path/WebHome"
    if [ -d "$attach_src" ] && [ -n "$(ls -A "$attach_src" 2>/dev/null)" ]; then
        mkdir -p "$out_assets_dir"
        ATTACH_COUNT=0
        while IFS= read -r src_file; do
            fname=$(basename "$src_file")
            cp "$src_file" "$out_assets_dir/$fname"
            if [ "$FLAT_ATTACHMENTS" = true ]; then
                # Rewrite links: ![[Note name/fname]] → ![[_attachments/fname]]
                escaped_note=$(printf '%s' "$note_name" | sed 's/[[\.*^$()+?{|]/\&/g')
                sed -i "s|!\[\[${escaped_note}/${fname}\]\]|![[_attachments/${fname}]]|g" "$out_md"
                sed -i "s|\[\[${escaped_note}/${fname}|\[\[_attachments/${fname}|g" "$out_md"
            fi
            ATTACH_COUNT=$((ATTACH_COUNT + 1))
        done < <(find "$attach_src" -maxdepth 1 -type f)
        log "$decoded_path.md  (+${ATTACH_COUNT} attachments)"
    else
        log "$decoded_path.md"
    fi

    COUNT_OK=$((COUNT_OK + 1))

done < <(find "$PAGES_DIR" -name "WebHome.html" -print0)

echo "========================================================"
echo " Done:   $COUNT_OK notes converted"
[ $COUNT_SKIP -gt 0 ] && echo " Skipped: $COUNT_SKIP (index pages)"
[ $COUNT_ERR -gt 0 ] && echo " Errors: $COUNT_ERR"
echo " Output: $OUTPUT_DIR"
echo "========================================================"
