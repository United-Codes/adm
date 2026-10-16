"""Generates the sample invoices of the course "Extract fields from template PDFs".

Every invoice uses the same template (an invented supplier, Harbour Office Supplies GmbH), with
other values. Each one adds one difficulty, named in its file name. The script writes the PDFs and
expected.json, the values that a correct extraction returns for each file.

    python3 make_invoices.py pdf

Every company, person, IBAN and number in the PDFs is invented.
"""
import json
import random
import sys
from datetime import date, timedelta
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas

OUT = Path(sys.argv[1]) if __name__ == "__main__" else None
random.seed(42)

W, H = A4
CATALOG = [
    ("PAP-A4-80", "Copy paper A4 80 g, box of 2,500 sheets", Decimal("24.90")),
    ("TON-HP-26X", "Toner cartridge HP 26X black", Decimal("142.50")),
    ("CHR-ERG-01", "Ergonomic office chair, model Aria", Decimal("389.00")),
    ("DSK-ELV-160", "Electric standing desk 160 x 80 cm", Decimal("649.00")),
    ("PEN-GEL-12", "Gel pens, blue, pack of 12", Decimal("8.40")),
    ("BND-RING-50", "Ring binders A4, 50 mm, pack of 10", Decimal("31.20")),
    ("LMP-LED-02", "LED desk lamp with USB charger", Decimal("54.75")),
    ("SRV-INST-H", "Installation service (per hour)", Decimal("68.00")),
    ("CAB-HDMI-2", "HDMI cable 2 m", Decimal("9.90")),
    ("MON-27-4K", "Monitor 27 inch 4K, height adjustable", Decimal("329.00")),
    ("WBD-120", "Whiteboard 120 x 90 cm, magnetic", Decimal("119.00")),
    ("SHR-P4", "Paper shredder, security level P-4", Decimal("189.90")),
]


def de(amount: Decimal) -> str:
    """German number format: 1.234,56"""
    q = amount.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    s = f"{abs(q):,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
    return ("-" if q < 0 else "") + s


def de_qty(q: Decimal) -> str:
    return str(q).replace(".", ",") if q != q.to_integral() else str(int(q))


def ddmmyyyy(d: date) -> str:
    return d.strftime("%d.%m.%Y")


def money(x: Decimal) -> Decimal:
    return x.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def lines_from(codes_qty):
    out = []
    for code, qty in codes_qty:
        item = next(c for c in CATALOG if c[0] == code)
        out.append({"item_number": code, "description": item[1], "quantity": Decimal(qty),
                    "unit_price": item[2], "amount": money(Decimal(qty) * item[2])})
    return out


def draw_header(c, inv, page, pages):
    # supplier block
    c.setFont("Helvetica-Bold", 16)
    c.drawString(20 * mm, H - 22 * mm, "Harbour Office Supplies GmbH")
    c.setFont("Helvetica", 8.5)
    c.drawString(20 * mm, H - 27 * mm, "Kaistrasse 14 · 20457 Hamburg · Germany")
    c.drawString(20 * mm, H - 31 * mm, "VAT ID DE 812 334 905 · +49 40 555 019 0 · billing@harbour-office.example")

    # document title and key facts box on the right
    c.setFont("Helvetica-Bold", 20)
    c.drawRightString(W - 20 * mm, H - 22 * mm, inv["title"])
    box_x, box_y, box_w, box_h = W - 85 * mm, H - 66 * mm, 65 * mm, 30 * mm
    c.rect(box_x, box_y, box_w, box_h)
    facts = [
        (inv["number_label"], inv["invoice_number"]),
        ("Date", ddmmyyyy(inv["invoice_date"])),
        ("Due date", ddmmyyyy(inv["due_date"]) if inv["due_date"] else "-"),
        ("Customer no.", inv["customer_number"]),
        ("Your order", inv["order_reference_shown"]),
    ]
    if inv["title"] == "DELIVERY NOTE":
        # a delivery note has a delivery date and no due date
        facts = [f for f in facts if f[0] != "Due date"]
        facts[1] = ("Delivery date", facts[1][1])
    c.setFont("Helvetica", 8.5)
    for i, (k, v) in enumerate(facts):
        y = box_y + box_h - 6 * mm - i * 5.2 * mm
        c.drawString(box_x + 3 * mm, y, k)
        c.drawRightString(box_x + box_w - 3 * mm, y, v)

    if page == 1:
        # bill-to and deliver-to blocks
        c.setFont("Helvetica-Bold", 8)
        c.drawString(20 * mm, H - 42 * mm, "BILL TO")
        c.drawString(20 * mm, H - 80 * mm, "DELIVER TO")
        c.setFont("Helvetica", 9.5)
        for i, line in enumerate(inv["bill_to"]):
            c.drawString(20 * mm, H - 47 * mm - i * 4.6 * mm, line)
        for i, line in enumerate(inv["deliver_to"]):
            c.drawString(20 * mm, H - 85 * mm - i * 4.6 * mm, line)

    c.setFont("Helvetica", 7.5)
    c.drawString(20 * mm, 12 * mm, "Harbour Office Supplies GmbH · Registered at Amtsgericht Hamburg HRB 177 204 · Managing director: Jana Petersen")
    c.drawRightString(W - 20 * mm, 12 * mm, f"Page {page} of {pages}")


COLS = [(20, "Pos"), (30, "Item no."), (55, "Description"), (140, "Qty"), (165, "Unit price"), (190, "Amount")]


def draw_table_head(c, y):
    c.setFont("Helvetica-Bold", 8.5)
    for x, label in COLS:
        if label in ("Qty", "Unit price", "Amount"):
            c.drawRightString(x * mm, y, label)
        else:
            c.drawString(x * mm, y, label)
    c.line(20 * mm, y - 2 * mm, W - 20 * mm, y - 2 * mm)
    return y - 7 * mm


def draw_row(c, y, pos, ln):
    c.setFont("Helvetica", 8.5)
    c.drawString(20 * mm, y, str(pos))
    c.drawString(30 * mm, y, ln["item_number"])
    c.drawString(55 * mm, y, ln["description"])
    c.drawRightString(140 * mm, y, de_qty(ln["quantity"]))
    c.drawRightString(165 * mm, y, de(ln["unit_price"]))
    c.drawRightString(190 * mm, y, de(ln["amount"]))


def render(inv, path, rows_first_page=22, rows_next_page=34):
    lines = inv["line_items"]
    first = lines[:rows_first_page]
    rest = lines[rows_first_page:]
    chunks = [first] + [rest[i:i + rows_next_page] for i in range(0, len(rest), rows_next_page)]
    pages = len(chunks)
    c = canvas.Canvas(str(path), pagesize=A4)
    c.setTitle(f"{inv['title'].title()} {inv['invoice_number']}")
    pos = 1
    running = Decimal("0")
    for p, chunk in enumerate(chunks, start=1):
        draw_header(c, inv, p, pages)
        y = H - (112 if p == 1 else 76) * mm
        y = draw_table_head(c, y)
        if p > 1:
            c.setFont("Helvetica-Oblique", 8.5)
            c.drawString(55 * mm, y, "Brought forward")
            c.drawRightString(190 * mm, y, de(running))
            y -= 5.5 * mm
        for ln in chunk:
            draw_row(c, y, pos, ln)
            running += ln["amount"]
            pos += 1
            y -= 5.5 * mm
        if p < pages:
            c.line(20 * mm, y + 3 * mm, W - 20 * mm, y + 3 * mm)
            c.setFont("Helvetica-Oblique", 8.5)
            c.drawString(55 * mm, y - 1 * mm, "Carried forward")
            c.drawRightString(190 * mm, y - 1 * mm, de(running))
            c.showPage()
            continue
        # totals block
        c.line(120 * mm, y + 3 * mm, W - 20 * mm, y + 3 * mm)
        y -= 2 * mm
        totals = [("Subtotal", de(inv["subtotal"]))]
        if inv["discount"]:
            totals.append((f"Discount {inv['discount_pct']} %", de(-inv["discount"])))
        totals += [
            ("Net amount", de(inv["net_amount"])),
            (f"VAT {inv['vat_rate']} %", de(inv["vat_amount"])),
        ]
        c.setFont("Helvetica", 9)
        for k, v in totals:
            c.drawString(125 * mm, y, k)
            c.drawRightString(190 * mm, y, v)
            y -= 5 * mm
        c.setFont("Helvetica-Bold", 10)
        c.drawString(125 * mm, y - 1 * mm, inv["total_label"])
        c.drawRightString(190 * mm, y - 1 * mm, f"EUR {de(inv['total_amount'])}")
        y -= 14 * mm
        c.setFont("Helvetica", 8.5)
        for line in inv["payment_text"]:
            c.drawString(20 * mm, y, line)
            y -= 4.4 * mm
        if inv["notes"]:
            y -= 3 * mm
            c.setFont("Helvetica-Bold", 8.5)
            c.drawString(20 * mm, y, "Notes")
            c.setFont("Helvetica", 8.5)
            for line in inv["notes"]:
                y -= 4.4 * mm
                c.drawString(20 * mm, y, line)
        c.showPage()
    c.save()


def build(case, number, d, cust_no, bill_to, lines, *, order_ref=None, deliver_to=None, notes=None,
          vat_rate=19, discount_pct=0, credit=False, due_days=30, customer_name=None):
    sign = Decimal("-1") if credit else Decimal("1")
    if credit:
        for ln in lines:
            ln["amount"] = -ln["amount"]
    subtotal = sum((ln["amount"] for ln in lines), Decimal("0"))
    discount = money(subtotal * Decimal(discount_pct) / 100) if discount_pct else Decimal("0")
    net = subtotal - discount
    vat = money(net * Decimal(vat_rate) / 100)
    total = net + vat
    due = None if credit else d + timedelta(days=due_days)
    inv = {
        "case": case,
        "title": "CREDIT NOTE" if credit else "INVOICE",
        "number_label": "Credit note no." if credit else "Invoice no.",
        "invoice_number": number,
        "invoice_date": d,
        "due_date": due,
        "customer_number": cust_no,
        "order_reference_shown": order_ref or "-",
        "bill_to": bill_to,
        "deliver_to": deliver_to or bill_to,
        "line_items": lines,
        "subtotal": subtotal,
        "discount": discount,
        "discount_pct": discount_pct,
        "net_amount": net,
        "vat_rate": vat_rate,
        "vat_amount": vat,
        "total_amount": total,
        "total_label": "Credit amount" if credit else "Total due",
        "payment_text": (["The credit amount will be refunded to your account within 14 days."] if credit else [
            f"Please transfer the total due by {ddmmyyyy(due)} to IBAN DE44 2005 0550 1234 5678 90, BIC HASPDEHHXXX.",
            f"Quote the invoice number {number} as the payment reference.",
        ]),
        "notes": notes or [],
    }
    fields = {
        "document_type": "credit_note" if credit else "invoice",
        "invoice_number": number,
        "invoice_date": d.isoformat(),
        "due_date": due.isoformat() if due else None,
        "customer_number": cust_no,
        "customer_name": customer_name or bill_to[0],
        "order_reference": order_ref,
        "discount_amount": float(discount),
        "net_amount": float(net),
        "vat_rate": vat_rate,
        "vat_amount": float(vat),
        "total_amount": float(total),
    }
    truth = {
        "form_code": "HARBOUR_INVOICE",
        "fields": fields,
        "line_items": [{"item_number": ln["item_number"], "quantity": float(ln["quantity"]),
                        "unit_price": float(ln["unit_price"]), "amount": float(ln["amount"])} for ln in lines],
    }
    return inv, truth


def main():
    ACME = ["Brightline Consulting AG", "Attn. Accounts Payable", "Neue Mainzer Strasse 52", "60311 Frankfurt am Main"]
    cases = [
        build("01-standard", "INV-2026-00412", date(2026, 3, 14), "C-10233", ACME,
              lines_from([("PAP-A4-80", 4), ("TON-HP-26X", 2), ("PEN-GEL-12", 10)]), order_ref="PO-77810"),
        build("02-single-line", "INV-2026-00415", date(2026, 3, 17), "C-10871",
              ["Kessler & Vogt Steuerberatung", "Hafenweg 3", "48155 Münster"],
              lines_from([("DSK-ELV-160", 1)]), order_ref="KV-2026-031"),
        build("03-day-month-ambiguous", "INV-2026-00431", date(2026, 4, 5), "C-10233", ACME,
              lines_from([("SRV-INST-H", "2.5"), ("MON-27-4K", 3), ("CAB-HDMI-2", 6), ("LMP-LED-02", 3),
                          ("BND-RING-50", 2), ("PAP-A4-80", 1), ("WBD-120", 1), ("PEN-GEL-12", 4)]),
              order_ref="PO-78002"),
        build("04-no-order-ref", "INV-2026-00440", date(2026, 4, 9), "C-11502",
              ["Lindqvist Architekten GmbH", "Speicherstadt 7", "20457 Hamburg"],
              lines_from([("SHR-P4", 1), ("PAP-A4-80", 2)])),
        build("05-different-delivery", "INV-2026-00447", date(2026, 4, 16), "C-10990",
              ["Rheinwerk Holding GmbH", "Finance Shared Services", "Postfach 10 22 40", "50462 Köln"],
              lines_from([("CHR-ERG-01", 6), ("DSK-ELV-160", 6)]), order_ref="RWH-4471-B",
              deliver_to=["Rheinwerk Logistik GmbH & Co. KG", "Site Manager: Tobias Brandt", "Industriestrasse 88",
                          "51149 Köln-Porz"]),
        build("06-notes-other-number", "INV-2026-00452", date(2026, 4, 22), "C-10233", ACME,
              lines_from([("TON-HP-26X", 4)]), order_ref="PO-78150",
              notes=["This invoice replaces invoice INV-2026-00388 dated 02.03.2026, which was issued with a wrong",
                     "customer number (C-10322). Please disregard INV-2026-00388. Order PO-77655 is not affected."]),
        build("07-large-amounts", "INV-2026-00460", date(2026, 5, 4), "C-12014",
              ["Stadtwerke Lüneburg GmbH", "Einkauf / Procurement", "Am Sande 1", "21335 Lüneburg"],
              lines_from([("DSK-ELV-160", 40), ("CHR-ERG-01", 40), ("MON-27-4K", 40)]), order_ref="BE-2026-0098"),
        build("08-discount", "INV-2026-00468", date(2026, 5, 11), "C-10871",
              ["Kessler & Vogt Steuerberatung", "Hafenweg 3", "48155 Münster"],
              lines_from([("MON-27-4K", 2), ("CAB-HDMI-2", 2), ("LMP-LED-02", 2)]), order_ref="KV-2026-044",
              discount_pct=5),
        build("09-credit-note", "CN-2026-0042", date(2026, 5, 19), "C-10233", ACME,
              lines_from([("TON-HP-26X", 1)]), order_ref="PO-78150", credit=True,
              notes=["Refers to invoice INV-2026-00452 dated 22.04.2026: one toner cartridge returned damaged."]),
        build("10-long-name", "INV-2026-00481", date(2026, 6, 1), "C-12230",
              ["Gemeinnützige Gesellschaft für Erwachsenenbildung", "und berufliche Weiterqualifizierung Nord mbH",
               "Bildungszentrum Wandsbek", "Wandsbeker Marktstrasse 71", "22041 Hamburg"],
              lines_from([("WBD-120", 4), ("PEN-GEL-12", 20), ("BND-RING-50", 6)]), order_ref="GGEB-BST-7713",
              vat_rate=7,
              customer_name="Gemeinnützige Gesellschaft für Erwachsenenbildung und berufliche Weiterqualifizierung Nord mbH"),
    ]
    # a long one that runs over two pages, with brought/carried forward subtotals
    codes = [c[0] for c in CATALOG]
    long_lines = lines_from([(codes[i % len(codes)], 1 + (i * 7) % 5) for i in range(31)])
    cases.append(build("11-two-pages", "INV-2026-00495", date(2026, 6, 12), "C-12014",
                       ["Stadtwerke Lüneburg GmbH", "Einkauf / Procurement", "Am Sande 1", "21335 Lüneburg"],
                       long_lines, order_ref="BE-2026-0131"))

    very_long = lines_from([(codes[(i * 5) % len(codes)], 1 + (i * 3) % 7) for i in range(120)])
    cases.append(build("13-five-pages", "INV-2026-00502", date(2026, 6, 30), "C-10233", ACME,
                       very_long, order_ref="PO-79001"))

    truths = {}
    for inv, truth in cases:
        render(inv, OUT / f"harbour-invoice-{inv['case']}.pdf")
        truths[f"harbour-invoice-{inv['case']}"] = truth
    (OUT / "expected.json").write_text(json.dumps(truths, indent=2, ensure_ascii=False))
    print(f"wrote {len(cases)} PDFs to {OUT}")



if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    main()
