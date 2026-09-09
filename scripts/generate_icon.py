#!/usr/bin/env python3
"""Generate FlyCommander app icon — homage to Total Commander.

macOS squircle, dual-pane layout, TC's classic blue palette.
"""
from PIL import Image, ImageDraw, ImageFont
import os

SIZE = 1024

# TC-inspired palette
BG        = (30, 36, 48)
HEADER    = (38, 80, 140)
PANE_BG   = (238, 242, 250)
ROW_ALT   = (222, 228, 240)
ROW_SEL   = (52, 120, 200)
COL_HDR   = (215, 220, 232)
DIVIDER   = (50, 58, 72)
STATUS_BG = (24, 30, 40)
ACCENT    = (70, 150, 230)
WHITE     = (255, 255, 255)
LIGHT     = (170, 180, 200)
DIM       = (130, 140, 160)
TEXT_DARK = (35, 40, 52)

img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Background squircle
d.rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=220, fill=BG)

# --- Layout ---
M = 68  # outer margin
STATUS_H = 52
GAP = 14

cx0, cy0 = M, M + 10
cx1, cy1 = SIZE - M, SIZE - M - 12
status_top = cy1 - STATUS_H
pane_bottom = status_top - 10

pane_w = (cx1 - cx0 - GAP) // 2
ph = pane_bottom - cy0

# Panes
lx0, ly0 = cx0, cy0
lx1, ly1 = lx0 + pane_w, pane_bottom
rx0, ry0 = lx1 + GAP, cy0
rx1, ry1 = rx0 + pane_w, pane_bottom

# Fonts
def font(size, mono=False):
    candidates = [
        "/System/Library/Fonts/SFNSMono.ttf" if mono else "/System/Library/Fonts/SFNSDisplay-Regular.otf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNSMono.ttf",
    ]
    for p in candidates:
        try: return ImageFont.truetype(p, size)
        except: pass
    return ImageFont.load_default()

font_path  = font(28, mono=True)
font_col   = font(20, mono=True)
font_row   = font(21, mono=True)
font_status = font(21, mono=True)
font_logo  = font(22)

def draw_pane(x0, y0, x1, y1, files, selected=2, path_text="/Users/docs"):
    h = y1 - y0
    hdr_h = min(64, int(h * 0.09))
    col_h = 28
    row_h = max(28, min(36, (h - hdr_h - col_h - 8) // len(files)))

    # Body
    d.rounded_rectangle((x0, y0, x1, y1), radius=14, fill=PANE_BG)

    # Header
    d.rounded_rectangle((x0, y0, x1, y0 + hdr_h), radius=14, fill=HEADER)
    d.rectangle((x0, y0 + hdr_h - 14, x1, y0 + hdr_h), fill=HEADER)
    d.text((x0 + 18, y0 + (hdr_h - 28) // 2), path_text, fill=WHITE, font=font_path)

    # Column headers
    col_y = y0 + hdr_h
    d.rectangle((x0, col_y, x1, col_y + col_h), fill=COL_HDR)
    d.text((x0 + 18, col_y + 4), "Name", fill=DIM, font=font_col)
    d.text((x1 - 160, col_y + 4), "Size", fill=DIM, font=font_col)
    d.text((x1 - 80, col_y + 4), "Date", fill=DIM, font=font_col)

    # Separator under column header
    d.line([(x0 + 1, col_y + col_h), (x1 - 1, col_y + col_h)], fill=(195, 200, 215), width=1)

    # Rows
    row_y0 = col_y + col_h
    for i, (name, sz, dt) in enumerate(files):
        ry = row_y0 + i * row_h
        if ry + row_h > y1 - 2:
            break
        sel = (i == selected)
        bg = ROW_SEL if sel else (ROW_ALT if i % 2 == 0 else PANE_BG)
        tc = WHITE if sel else TEXT_DARK
        dc = (200, 215, 240) if sel else DIM
        d.rectangle((x0 + 1, ry, x1 - 1, ry + row_h - 1), fill=bg)
        d.text((x0 + 18, ry + (row_h - 22) // 2), name, fill=tc, font=font_row)
        d.text((x1 - 160, ry + (row_h - 22) // 2), sz, fill=dc, font=font_row)
        d.text((x1 - 80, ry + (row_h - 22) // 2), dt, fill=dc, font=font_row)

    # Border
    d.rounded_rectangle((x0, y0, x1, y1), radius=14, outline=DIVIDER, width=2)


left_files = [
    ("📁 Documents",   "—",      "09/08"),
    ("📁 Projects",    "—",      "09/07"),
    ("📄 readme.md",   "4.2 KB", "09/06"),
    ("📊 data.xlsx",   "128 KB", "09/05"),
    ("🖼 photo.jpg",   "2.1 MB", "09/04"),
    ("📦 backup.zip",  "45 MB",  "09/03"),
    ("📄 notes.txt",   "1.8 KB", "09/02"),
    ("🎵 music.mp3",  "5.6 MB", "09/01"),
    ("📄 config.yml",  "0.8 KB", "08/30"),
    ("📁 Archives",    "—",      "08/28"),
    ("📄 index.html",  "12 KB",  "08/25"),
    ("⚙  setup.sh",   "3.4 KB", "08/20"),
]

right_files = [
    ("📁 System",      "—",      "09/08"),
    ("📁 Library",     "—",      "09/07"),
    ("📄 .gitignore",  "0.5 KB", "09/06"),
    ("📄 Makefile",    "2.1 KB", "09/05"),
    ("⚙  build.sh",   "1.2 KB", "09/04"),
    ("📄 LICENSE",     "1.1 KB", "09/03"),
    ("📁 Sources",     "—",      "09/02"),
    ("📄 README.md",   "8.3 KB", "09/01"),
    ("📄 package.json","0.6 KB", "08/30"),
    ("📁 Tests",       "—",      "08/28"),
    ("📄 changelog.md","4.7 KB", "08/25"),
    ("📄 .env.example","0.2 KB", "08/20"),
]

draw_pane(lx0, ly0, lx1, ly1, left_files,  selected=2, path_text="/Users/docs")
draw_pane(rx0, ry0, rx1, ry1, right_files, selected=4, path_text="/Volumes/bak")

# --- Status bar ---
d.rounded_rectangle((cx0, status_top, cx1, cy1), radius=10, fill=STATUS_BG)
d.text((cx0 + 18, status_top + 14), "12 items · 45.2 MB", fill=LIGHT, font=font_status)
d.text((cx1 - 220, status_top + 14), "⌘ FlyCommander", fill=ACCENT, font=font_logo)

# --- Save all sizes ---
out = os.path.dirname(os.path.abspath(__file__))
for s in [16, 32, 64, 128, 256, 512, 1024]:
    img.resize((s, s), Image.LANCZOS).save(os.path.join(out, f"icon_{s}.png"))
print(f"✓ Generated icon PNGs ({out})")
