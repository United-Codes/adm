"""Makes the "scanned" samples: images, and a PDF without a text layer.

Needs pdftoppm (poppler) and reportlab. Run it after make_invoices.py and make_forms.py:

    python3 make_scans.py pdf inbox

pdf/harbour-invoice-12-scanned.png    harbour-invoice-04-no-order-ref.pdf as a 150 dpi image
pdf/harbour-invoice-12-scanned.pdf    the same image in a PDF, so the PDF has no text that can be extracted
pdf/nordwind-invoice-05-photo.png     nordwind-invoice-02-reverse-charge.pdf as a 150 dpi image
inbox/inbox-nordwind-photo.png        inbox-nordwind-invoice.pdf as an image
inbox/inbox-harbour-scanned.pdf       inbox-harbour-delivery.pdf as a PDF without text
"""
import json
import subprocess
import sys
from pathlib import Path

from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas

OUT = Path(sys.argv[1])
INBOX = Path(sys.argv[2])


def to_png(source: Path, target: Path):
    subprocess.run(["pdftoppm", "-r", "150", "-png", "-singlefile", str(source), str(target.with_suffix(""))], check=True)


def to_image_pdf(png: Path, target: Path):
    c = canvas.Canvas(str(target), pagesize=A4)
    c.drawImage(str(png), 0, 0, width=A4[0], height=A4[1])
    c.showPage()
    c.save()


expected_file = OUT / "expected.json"
expected = json.loads(expected_file.read_text())
to_png(OUT / "harbour-invoice-04-no-order-ref.pdf", OUT / "harbour-invoice-12-scanned.png")
to_image_pdf(OUT / "harbour-invoice-12-scanned.png", OUT / "harbour-invoice-12-scanned.pdf")
expected["harbour-invoice-12-scanned"] = expected["harbour-invoice-04-no-order-ref"]
to_png(OUT / "nordwind-invoice-02-reverse-charge.pdf", OUT / "nordwind-invoice-05-photo.png")
expected["nordwind-invoice-05-photo"] = expected["nordwind-invoice-02-reverse-charge"]
expected_file.write_text(json.dumps(expected, indent=2, ensure_ascii=False))

inbox_file = INBOX / "expected.json"
inbox = json.loads(inbox_file.read_text())
to_png(INBOX / "inbox-nordwind-invoice.pdf", INBOX / "inbox-nordwind-photo.png")
inbox["inbox-nordwind-photo"] = inbox["inbox-nordwind-invoice"]
(INBOX / "inbox-nordwind-invoice.pdf").unlink()
del inbox["inbox-nordwind-invoice"]
tmp = INBOX / "delivery.png"
to_png(INBOX / "inbox-harbour-delivery.pdf", tmp)
to_image_pdf(tmp, INBOX / "inbox-harbour-scanned.pdf")
tmp.unlink()
inbox["inbox-harbour-scanned"] = inbox["inbox-harbour-delivery"]
inbox_file.write_text(json.dumps(inbox, indent=2, ensure_ascii=False))
print("wrote the scans")
