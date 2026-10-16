#!/usr/bin/env python3
"""Builds the figures of the course "Extract data from PDF forms" from the sample PDFs.

Boxes are placed from the word coordinates of `pdftotext -bbox`, so they sit on the real values.
Usage: make_figs.py <samples/pdf dir> <output dir>
"""
import html
import re
import subprocess
import sys
from pathlib import Path

SAMPLES = Path(sys.argv[1])
OUT = Path(sys.argv[2])
WORK = Path("/tmp/pfx_figs/work")
WORK.mkdir(parents=True, exist_ok=True)
DPI = 144
K = DPI / 72.0
FONT = "/System/Library/Fonts/Menlo.ttc"
TEXT_FONT = "/System/Library/Fonts/HelveticaNeue.ttc"

# one colour per field, the same in every figure
COLORS = {
    "invoice_number": "#d1495b",
    "delivery_note_number": "#d1495b",
    "invoice_date": "#b7791f",
    "delivery_date": "#b7791f",
    "customer_number": "#00798c",
    "customer_name": "#30638e",
    "order_reference": "#8f5aa8",
    "line_items": "#2e933c",
    "net_amount": "#c06014",
    "vat_amount": "#7a6c5d",
    "total_amount": "#003d5b",
    "total_quantity": "#003d5b",
}


def words(pdf):
    out = subprocess.run(["pdftotext", "-bbox", "-f", "1", "-l", "1", str(pdf), "-"],
                         capture_output=True, text=True, check=True).stdout
    res = []
    for m in re.finditer(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>', out):
        res.append((float(m[1]), float(m[2]), float(m[3]), float(m[4]), html.unescape(m[5])))
    return res


def find(ws, phrase, nth=1):
    """bbox of the nth occurrence of a phrase of consecutive words"""
    toks = phrase.split()
    hit = 0
    for i in range(len(ws) - len(toks) + 1):
        if all(ws[i + j][4] == toks[j] for j in range(len(toks))):
            hit += 1
            if hit == nth:
                sel = ws[i:i + len(toks)]
                return (min(w[0] for w in sel), min(w[1] for w in sel), max(w[2] for w in sel), max(w[3] for w in sel))
    raise SystemExit(f"not found: {phrase!r} #{nth}")


def union(*boxes):
    return (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))


def render(name):
    png = WORK / f"{name}.png"
    if not png.exists():
        subprocess.run(["pdftoppm", "-r", str(DPI), "-png", "-singlefile", str(SAMPLES / f"{name}.pdf"),
                        str(WORK / name)], check=True)
    return png


def annotate(name, fields, crop_pt, out, margin=300, x_from=38, x_to=557):
    """fields: list of (field, bbox in pt). Labels go into a margin on the side nearer to the box."""
    src = render(name)
    page_w = int((x_to - x_from) * K)
    crop_h = int(crop_pt * K)
    cmd = ["magick", str(src), "-crop", f"{page_w}x{crop_h}+{int(x_from * K)}+0", "+repage",
           "-bordercolor", "#bbbbbb", "-border", "1",
           "-background", "white", "-gravity", "center", "-extent", f"{page_w + 2 * margin}x{crop_h + 2}",
           "-gravity", "northwest", "-font", FONT, "-pointsize", "25"]
    placed = {"L": [], "R": []}
    items = []
    for field, b in fields:
        x0, y0, x1, y1 = ((b[0] - x_from) * K - 5 + margin, b[1] * K - 5, (b[2] - x_from) * K + 5 + margin, b[3] * K + 5)
        side = "L" if (x0 + x1) / 2 < margin + page_w / 2 else "R"
        items.append((field, (x0, y0, x1, y1), side))
    for side in "LR":
        ys = sorted([it for it in items if it[2] == side], key=lambda it: (it[1][1] + it[1][3]) / 2)
        last = -100
        for field, (x0, y0, x1, y1), _ in ys:
            ly = max((y0 + y1) / 2, last + 34)
            last = ly
            placed[side].append((field, (x0, y0, x1, y1), ly))
    for side, lst in placed.items():
        for field, (x0, y0, x1, y1), ly in lst:
            c = COLORS[field]
            cmd += ["-fill", "none", "-stroke", c, "-strokewidth", "3",
                    "-draw", f"rectangle {x0:.0f},{y0:.0f} {x1:.0f},{y1:.0f}"]
            if side == "L":
                tx = 12
                lx_end = margin - 8
                cmd += ["-strokewidth", "2", "-draw", f"line {x0:.0f},{(y0 + y1) / 2:.0f} {lx_end},{ly:.0f}",
                        "-draw", f"line {lx_end},{ly:.0f} {tx + len(field) * 15.2 + 6:.0f},{ly:.0f}"]
            else:
                tx = margin + page_w + 14
                cmd += ["-strokewidth", "2", "-draw", f"line {x1:.0f},{(y0 + y1) / 2:.0f} {tx - 6},{ly:.0f}"]
            cmd += ["-stroke", "none", "-fill", c, "-annotate", f"+{tx}+{ly - 15:.0f}", field]
    cmd += [str(out)]
    subprocess.run(cmd, check=True)


def caption(img, lines, out):
    subprocess.run(["magick", str(img), "-background", "white", "-gravity", "center",
                    "-font", TEXT_FONT, "-pointsize", "30", "-fill", "#222222",
                    f"label:{lines}", "-append", str(out)], check=True)


OUT.mkdir(parents=True, exist_ok=True)

# --- 1. three forms side by side --------------------------------------------------------
parts = []
for name, cap in [("harbour-invoice-01-standard", "form HARBOUR_INVOICE\ndocument type invoice"),
                  ("nordwind-invoice-01-standard", "form NORDWIND_INVOICE\ndocument type invoice"),
                  ("harbour-delivery-02-partial", "form HARBOUR_DELIVERY_NOTE\ndocument type delivery_note")]:
    src = render(name)
    cropped = WORK / f"{name}-top.png"
    subprocess.run(["magick", str(src), "-crop", f"{int(595.28 * K)}x{int(452 * K)}+0+0", "+repage",
                    "-bordercolor", "#bbbbbb", "-border", "2", str(cropped)], check=True)
    capped = WORK / f"{name}-cap.png"
    caption(cropped, cap, capped)
    parts.append(str(capped))
subprocess.run(["magick", *parts, "-bordercolor", "white", "-border", "18", "+append",
                "-resize", "1800x", str(OUT / "pfx-three-forms.png")], check=True)

# --- 2. the same fields on two invoice forms ---------------------------------------------
hw = words(SAMPLES / "harbour-invoice-01-standard.pdf")
harbour = [
    ("invoice_number", find(hw, "INV-2026-00412")),
    ("invoice_date", find(hw, "14.03.2026")),
    ("customer_number", find(hw, "C-10233")),
    ("order_reference", find(hw, "PO-77810")),
    ("customer_name", find(hw, "Brightline Consulting AG")),
    ("line_items", union(find(hw, "Pos"), find(hw, "84,00"))),
    ("net_amount", find(hw, "468,60", 2)),
    ("vat_amount", find(hw, "89,03")),
    ("total_amount", find(hw, "EUR 557,63")),
]
annotate("harbour-invoice-01-standard", harbour, 450, WORK / "harbour-fields.png")

nw = words(SAMPLES / "nordwind-invoice-01-standard.pdf")
nordwind = [
    ("invoice_number", find(nw, "NWL/26/10482")),
    ("invoice_date", find(nw, "14 Mar 2026")),
    ("customer_number", find(nw, "400-2213")),
    ("order_reference", find(nw, "4500127733")),
    ("customer_name", find(nw, "Van Dijk Bouwmaterialen B.V.")),
    ("line_items", union(find(nw, "Code"), find(nw, "18.40", 2))),
    ("net_amount", find(nw, "589.60")),
    ("vat_amount", find(nw, "123.82")),
    ("total_amount", find(nw, "713.42")),
]
annotate("nordwind-invoice-01-standard", nordwind, 390, WORK / "nordwind-fields.png")
caption(WORK / "harbour-fields.png", "HARBOUR_INVOICE: German number and date format", WORK / "h.png")
caption(WORK / "nordwind-fields.png", "NORDWIND_INVOICE: English number and date format", WORK / "n.png")
subprocess.run(["magick", str(WORK / "h.png"), str(WORK / "n.png"), "-bordercolor", "white", "-border", "14",
                "-append", "-resize", "1500x", str(OUT / "pfx-invoice-fields.png")], check=True)

# --- 3. the delivery note ------------------------------------------------------------------
dw = words(SAMPLES / "harbour-delivery-02-partial.pdf")
delivery = [
    ("delivery_note_number", find(dw, "DN-2026-0764")),
    ("delivery_date", find(dw, "14.04.2026")),
    ("customer_number", find(dw, "C-10990")),
    ("order_reference", find(dw, "RWH-4471-B")),
    ("customer_name", find(dw, "Rheinwerk Holding GmbH")),
    ("line_items", union(find(dw, "Pos"), find(dw, "6 6 0"))),
    ("total_quantity", find(dw, "Total delivered 10")),
]
annotate("harbour-delivery-02-partial", delivery, 400, WORK / "delivery-fields.png")
subprocess.run(["magick", str(WORK / "delivery-fields.png"), "-resize", "1500x", str(OUT / "pfx-delivery-note-fields.png")], check=True)

# --- 4. the two images ---------------------------------------------------------------------
imgs = []
for name, cap in [("harbour-invoice-12-scanned.png", "harbour-invoice-12-scanned.png"),
                  ("nordwind-invoice-05-photo.png", "nordwind-invoice-05-photo.png")]:
    small = WORK / f"img-{name}"
    subprocess.run(["magick", str(SAMPLES / name), "-resize", "x900", "-bordercolor", "#bbbbbb", "-border", "2",
                    str(small)], check=True)
    capped = WORK / f"cap-{name}"
    caption(small, cap, capped)
    imgs.append(str(capped))
subprocess.run(["magick", *imgs, "-bordercolor", "white", "-border", "16", "-gravity", "north", "+append",
                "-resize", "1400x", str(OUT / "pfx-image-samples.png")], check=True)
print("done")
