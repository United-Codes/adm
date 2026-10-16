"""Generates the samples of the other forms: Nordwind Logistics invoices, Harbour delivery notes,
a Harbour letter that is no form, and the new files of the inbox (lesson 5).

Run it after make_invoices.py, because it adds to expected.json:

    python3 make_forms.py pdf inbox

Every company, person, IBAN and number in the PDFs is invented.
"""
import json
import sys
from datetime import date
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas

from make_invoices import CATALOG, build, draw_header as harbour_header, lines_from, render

OUT = Path(sys.argv[1])
INBOX = Path(sys.argv[2])
INBOX.mkdir(parents=True, exist_ok=True)
W, H = A4


def money(x: Decimal) -> Decimal:
    return x.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def en(amount: Decimal) -> str:
    """English number format: 1,234.56"""
    return f"{money(amount):,.2f}"


def dmy_text(d: date) -> str:
    return d.strftime("%d %b %Y")


# ---------------------------------------------------------------------------
# Nordwind Logistics B.V.: freight invoices, English number format
# ---------------------------------------------------------------------------
SERVICES = {
    "FRT-PAL": ("Pallet transport {route}", "pallet", Decimal("85.00")),
    "FRT-FTL": ("Full truck load {route}", "trip", Decimal("1240.00")),
    "FUEL": ("Fuel surcharge", "flat", None),
    "TOLL": ("Road toll", "flat", None),
    "WAIT": ("Waiting time at loading point", "hour", Decimal("45.00")),
    "ADR": ("Dangerous goods handling (ADR)", "flat", Decimal("65.00")),
}


def nordwind_lines(spec, route):
    out = []
    for code, qty, price in spec:
        text, unit, default = SERVICES[code]
        unit_price = Decimal(price) if price is not None else default
        out.append({"item_number": code, "description": text.format(route=route), "unit": unit,
                    "quantity": Decimal(qty), "unit_price": unit_price,
                    "amount": money(Decimal(qty) * unit_price)})
    return out


def nordwind(path, number, d, due, account, customer, po, shipment, route, spec, vat_rate):
    lines = nordwind_lines(spec, route)
    net = sum((ln["amount"] for ln in lines), Decimal("0"))
    vat = money(net * Decimal(vat_rate) / 100)
    total = net + vat
    c = canvas.Canvas(str(path), pagesize=A4)
    c.setTitle(f"Freight invoice {number}")

    c.setFillColorRGB(0.05, 0.22, 0.38)
    c.rect(0, H - 30 * mm, W, 30 * mm, fill=1, stroke=0)
    c.setFillColorRGB(1, 1, 1)
    c.setFont("Helvetica-Bold", 18)
    c.drawString(18 * mm, H - 16 * mm, "NORDWIND LOGISTICS")
    c.setFont("Helvetica", 8)
    c.drawString(18 * mm, H - 22 * mm, "Nordwind Logistics B.V. | Waalhaven Oostzijde 120 | 3087 BM Rotterdam | The Netherlands")
    c.drawString(18 * mm, H - 26 * mm, "VAT NL854122736B01 | KvK 72410593 | accounts@nordwind-logistics.example")
    c.setFont("Helvetica-Bold", 14)
    c.drawRightString(W - 18 * mm, H - 18 * mm, "FREIGHT INVOICE")
    c.setFillColorRGB(0, 0, 0)

    # customer on the left, facts on the right, as label: value lines
    c.setFont("Helvetica-Bold", 9)
    c.drawString(18 * mm, H - 42 * mm, "Invoice to:")
    c.setFont("Helvetica", 9.5)
    for i, line in enumerate(customer):
        c.drawString(18 * mm, H - 48 * mm - i * 4.6 * mm, line)
    facts = [
        ("Invoice No:", number),
        ("Invoice Date:", dmy_text(d)),
        ("Due Date:", dmy_text(due)),
        ("Account:", account),
        ("Your PO:", po or "n/a"),
        ("Shipment:", shipment),
    ]
    for i, (k, v) in enumerate(facts):
        y = H - 42 * mm - i * 5 * mm
        c.setFont("Helvetica-Bold", 9)
        c.drawString(120 * mm, y, k)
        c.setFont("Helvetica", 9)
        c.drawString(148 * mm, y, v)

    # table
    y = H - 86 * mm
    cols = [(18, "Code", "l"), (38, "Service", "l"), (128, "Qty", "r"), (142, "Unit", "l"), (172, "Rate EUR", "r"),
            (W / mm - 18, "Amount EUR", "r")]
    c.setFillColorRGB(0.9, 0.93, 0.96)
    c.rect(18 * mm, y - 2 * mm, W - 36 * mm, 7 * mm, fill=1, stroke=0)
    c.setFillColorRGB(0, 0, 0)
    c.setFont("Helvetica-Bold", 8.5)
    for x, label, align in cols:
        (c.drawRightString if align == "r" else c.drawString)(x * mm, y, label)
    y -= 8 * mm
    c.setFont("Helvetica", 8.5)
    for ln in lines:
        values = [ln["item_number"], ln["description"], str(int(ln["quantity"])) if ln["quantity"] == ln["quantity"].to_integral() else str(ln["quantity"]),
                  ln["unit"], en(ln["unit_price"]), en(ln["amount"])]
        for (x, _, align), v in zip(cols, values):
            (c.drawRightString if align == "r" else c.drawString)(x * mm, y, v)
        y -= 5.5 * mm

    y -= 4 * mm
    c.line(110 * mm, y + 3 * mm, W - 18 * mm, y + 3 * mm)
    y -= 2 * mm
    c.setFont("Helvetica", 9)
    vat_label = f"VAT {vat_rate}%" if vat_rate else "VAT 0% (reverse charge, art. 196 VAT Directive)"
    for k, v in [("Net amount", en(net)), (vat_label, en(vat))]:
        c.drawString(110 * mm, y, k)
        c.drawRightString(W - 18 * mm, y, v)
        y -= 5 * mm
    c.setFont("Helvetica-Bold", 10)
    c.drawString(110 * mm, y - 1 * mm, "Total EUR")
    c.drawRightString(W - 18 * mm, y - 1 * mm, en(total))

    c.setFont("Helvetica", 8)
    y = 40 * mm
    for line in [f"Payment within 30 days to IBAN NL20 INGB 0001 2345 67, BIC INGBNL2A, reference {number}.",
                 "All transports are carried out under the general conditions of the Dutch Transport Operators (AVC 2002).",
                 f"Questions about this invoice? Please quote your account {account} and shipment {shipment}."]:
        c.drawString(18 * mm, y, line)
        y -= 4.4 * mm
    c.showPage()
    c.save()

    return {
        "form_code": "NORDWIND_INVOICE",
        "fields": {
            "document_type": "invoice",
            "invoice_number": number,
            "invoice_date": d.isoformat(),
            "due_date": due.isoformat(),
            "customer_number": account,
            "customer_name": customer[0],
            "order_reference": po,
            "discount_amount": 0,
            "net_amount": float(net),
            "vat_rate": vat_rate,
            "vat_amount": float(vat),
            "total_amount": float(total),
        },
        "line_items": [{"item_number": ln["item_number"], "quantity": float(ln["quantity"]),
                        "unit_price": float(ln["unit_price"]), "amount": float(ln["amount"])} for ln in lines],
    }


# ---------------------------------------------------------------------------
# Harbour Office Supplies: delivery notes, same letterhead as the invoices
# ---------------------------------------------------------------------------
def harbour_delivery(path, number, d, cust_no, sold_to, ship_to, order_ref, items, carrier):
    """items: (code, ordered, delivered)"""
    head = {
        "title": "DELIVERY NOTE",
        "number_label": "Delivery note no.",
        "invoice_number": number,
        "invoice_date": d,
        "due_date": None,
        "customer_number": cust_no,
        "order_reference_shown": order_ref,
        "bill_to": sold_to,
        "deliver_to": ship_to,
    }
    c = canvas.Canvas(str(path), pagesize=A4)
    c.setTitle(f"Delivery note {number}")
    harbour_header(c, head, 1, 1)
    # the invoice header prints "Due date"; a delivery note has none, the header prints "-"
    y = H - 112 * mm
    cols = [(20, "Pos", "l"), (30, "Item no.", "l"), (55, "Description", "l"), (150, "Ordered", "r"),
            (170, "Delivered", "r"), (190, "Open", "r")]
    c.setFont("Helvetica-Bold", 8.5)
    for x, label, align in cols:
        (c.drawRightString if align == "r" else c.drawString)(x * mm, y, label)
    c.line(20 * mm, y - 2 * mm, W - 20 * mm, y - 2 * mm)
    y -= 7 * mm
    c.setFont("Helvetica", 8.5)
    lines = []
    for pos, (code, ordered, delivered) in enumerate(items, start=1):
        desc = next(x[1] for x in CATALOG if x[0] == code)
        for (x, _, align), v in zip(cols, [str(pos), code, desc, str(ordered), str(delivered), str(ordered - delivered)]):
            (c.drawRightString if align == "r" else c.drawString)(x * mm, y, v)
        lines.append({"item_number": code, "quantity": float(delivered)})
        y -= 5.5 * mm
    total_qty = sum(i[2] for i in items)
    c.line(120 * mm, y + 3 * mm, W - 20 * mm, y + 3 * mm)
    c.setFont("Helvetica-Bold", 9)
    c.drawString(125 * mm, y - 2 * mm, "Total delivered")
    c.drawRightString(170 * mm, y - 2 * mm, str(total_qty))
    y -= 16 * mm
    c.setFont("Helvetica", 8.5)
    open_items = [i for i in items if i[1] > i[2]]
    text = [f"Carrier: {carrier}", f"Packages: {max(1, len(items) // 2)}"]
    if open_items:
        text.append("Open quantities follow in a separate delivery. You will be invoiced for delivered goods only.")
    text.append("Please check the goods on receipt and report damage within 5 working days.")
    text.append("Received in good condition: ______________________  Date: ____________")
    for line in text:
        c.drawString(20 * mm, y, line)
        y -= 4.6 * mm
    c.showPage()
    c.save()
    return {
        "form_code": "HARBOUR_DELIVERY_NOTE",
        "fields": {
            "delivery_note_number": number,
            "delivery_date": d.isoformat(),
            "customer_number": cust_no,
            "customer_name": sold_to[0],
            "order_reference": order_ref,
            "total_quantity": total_qty,
        },
        "line_items": lines,
    }


# ---------------------------------------------------------------------------
# A Harbour letter: same letterhead, but no form
# ---------------------------------------------------------------------------
def harbour_letter(path):
    c = canvas.Canvas(str(path), pagesize=A4)
    c.setTitle("Price adjustment")
    c.setFont("Helvetica-Bold", 16)
    c.drawString(20 * mm, H - 22 * mm, "Harbour Office Supplies GmbH")
    c.setFont("Helvetica", 8.5)
    c.drawString(20 * mm, H - 27 * mm, "Kaistrasse 14 · 20457 Hamburg · Germany")
    c.drawString(20 * mm, H - 31 * mm, "VAT ID DE 812 334 905 · +49 40 555 019 0 · billing@harbour-office.example")
    c.setFont("Helvetica", 9.5)
    for i, line in enumerate(["Brightline Consulting AG", "Attn. Accounts Payable", "Neue Mainzer Strasse 52", "60311 Frankfurt am Main"]):
        c.drawString(20 * mm, H - 50 * mm - i * 4.6 * mm, line)
    c.drawRightString(W - 20 * mm, H - 50 * mm, "Hamburg, 02.06.2026")
    c.drawRightString(W - 20 * mm, H - 55 * mm, "Customer no. C-10233")
    c.setFont("Helvetica-Bold", 11)
    c.drawString(20 * mm, H - 80 * mm, "Price adjustment from 1 July 2026")
    c.setFont("Helvetica", 9.5)
    body = [
        "Dear Sir or Madam,",
        "",
        "paper prices have risen again this year. From 1 July 2026, the following prices change:",
        "",
        "    PAP-A4-80   Copy paper A4 80 g, box of 2,500 sheets        24,90  ->  26,40 EUR",
        "    BND-RING-50 Ring binders A4, 50 mm, pack of 10              31,20  ->  32,90 EUR",
        "",
        "Orders that we receive before 1 July 2026 are delivered and invoiced at the old prices.",
        "Your next invoice after that date shows the new prices. All other prices stay the same.",
        "",
        "Your framework order PO-77810 is not affected until its end on 31.12.2026.",
        "",
        "Kind regards",
        "",
        "Jana Petersen",
        "Managing director",
    ]
    y = H - 92 * mm
    for line in body:
        c.drawString(20 * mm, y, line)
        y -= 5.2 * mm
    c.setFont("Helvetica", 7.5)
    c.drawString(20 * mm, 12 * mm, "Harbour Office Supplies GmbH · Registered at Amtsgericht Hamburg HRB 177 204 · Managing director: Jana Petersen")
    c.showPage()
    c.save()
    return {"form_code": None, "fields": None, "line_items": None}


VAN_DIJK = ["Van Dijk Bouwmaterialen B.V.", "t.a.v. Crediteurenadministratie", "Industrieweg 41", "3044 AS Rotterdam", "The Netherlands"]
BRIGHT = ["Brightline Consulting AG", "Attn. Accounts Payable", "Neue Mainzer Strasse 52", "60311 Frankfurt am Main", "Germany"]
LINDQ = ["Lindqvist Architekten GmbH", "Speicherstadt 7", "20457 Hamburg", "Germany"]

expected_file = OUT / "expected.json"
expected = json.loads(expected_file.read_text())

expected["nordwind-invoice-01-standard"] = nordwind(
    OUT / "nordwind-invoice-01-standard.pdf", "NWL/26/10482", date(2026, 3, 14), date(2026, 4, 13),
    "400-2213", VAN_DIJK, "4500127733", "SHP-88412", "Rotterdam - Antwerp",
    [("FRT-PAL", 6, None), ("FUEL", 1, "61.20"), ("TOLL", 1, "18.40")], 21)
expected["nordwind-invoice-02-reverse-charge"] = nordwind(
    OUT / "nordwind-invoice-02-reverse-charge.pdf", "NWL/26/10517", date(2026, 3, 30), date(2026, 4, 29),
    "400-3870", BRIGHT, "PO-77902", "SHP-88695", "Rotterdam - Frankfurt",
    [("FRT-FTL", 1, None), ("WAIT", 2, None), ("FUEL", 1, "148.80")], 0)
expected["nordwind-invoice-03-no-po"] = nordwind(
    OUT / "nordwind-invoice-03-no-po.pdf", "NWL/26/10566", date(2026, 4, 21), date(2026, 5, 21),
    "400-2213", VAN_DIJK, None, "SHP-89020", "Rotterdam - Utrecht",
    [("FRT-PAL", 3, None), ("ADR", 1, None)], 21)
expected["nordwind-invoice-04-large"] = nordwind(
    OUT / "nordwind-invoice-04-large.pdf", "NWL/26/10603", date(2026, 5, 6), date(2026, 6, 5),
    "400-4102", LINDQ, "LA-2026-118", "SHP-89377", "Hamburg - Rotterdam",
    [("FRT-FTL", 4, None), ("FRT-PAL", 12, None), ("ADR", 2, None), ("FUEL", 1, "697.20"), ("TOLL", 4, "92.10")], 0)

ACME = ["Brightline Consulting AG", "Attn. Accounts Payable", "Neue Mainzer Strasse 52", "60311 Frankfurt am Main"]
expected["harbour-delivery-01-complete"] = harbour_delivery(
    OUT / "harbour-delivery-01-complete.pdf", "DN-2026-0731", date(2026, 3, 12), "C-10233", ACME, ACME, "PO-77810",
    [("PAP-A4-80", 4, 4), ("TON-HP-26X", 2, 2), ("PEN-GEL-12", 10, 10)], "Nordwind Logistics B.V.")
expected["harbour-delivery-02-partial"] = harbour_delivery(
    OUT / "harbour-delivery-02-partial.pdf", "DN-2026-0764", date(2026, 4, 14), "C-10990",
    ["Rheinwerk Holding GmbH", "Finance Shared Services", "Postfach 10 22 40", "50462 Köln"],
    ["Rheinwerk Logistik GmbH & Co. KG", "Site Manager: Tobias Brandt", "Industriestrasse 88", "51149 Köln-Porz"],
    "RWH-4471-B", [("CHR-ERG-01", 6, 4), ("DSK-ELV-160", 6, 6)], "Nordwind Logistics B.V.")
expected["harbour-delivery-03-backorder"] = harbour_delivery(
    OUT / "harbour-delivery-03-backorder.pdf", "DN-2026-0802", date(2026, 5, 2), "C-12014",
    ["Stadtwerke Lüneburg GmbH", "Einkauf / Procurement", "Am Sande 1", "21335 Lüneburg"],
    ["Stadtwerke Lüneburg GmbH", "Lager Nord", "Bei der Pferdehütte 10", "21339 Lüneburg"],
    "BE-2026-0098", [("DSK-ELV-160", 40, 25), ("CHR-ERG-01", 40, 40), ("MON-27-4K", 40, 0)], "own vehicle")
expected["harbour-letter-prices"] = harbour_letter(OUT / "harbour-letter-prices.pdf")
expected_file.write_text(json.dumps(expected, indent=2, ensure_ascii=False))

# ---------------------------------------------------------------------------
# The inbox of lesson 5: new files, not in the test set
# ---------------------------------------------------------------------------
inbox = {}
inv, truth = build("inbox", "INV-2026-01107", date(2026, 9, 30), "C-12230",
                   ["Gemeinnützige Gesellschaft für Erwachsenenbildung", "und berufliche Weiterqualifizierung Nord mbH",
                    "Bildungszentrum Wandsbek", "Wandsbeker Marktstrasse 71", "22041 Hamburg"],
                   lines_from([("PAP-A4-80", 6), ("BND-RING-50", 4), ("WBD-120", 1)]), order_ref="GGEB-BST-8020", vat_rate=7,
                   customer_name="Gemeinnützige Gesellschaft für Erwachsenenbildung und berufliche Weiterqualifizierung Nord mbH")
render(inv, INBOX / "inbox-harbour-invoice.pdf")
inbox["inbox-harbour-invoice"] = truth
inbox["inbox-nordwind-invoice"] = nordwind(
    INBOX / "inbox-nordwind-invoice.pdf", "NWL/26/10988", date(2026, 9, 29), date(2026, 10, 29),
    "400-2213", VAN_DIJK, "4500131204", "SHP-91744", "Rotterdam - Gent",
    [("FRT-PAL", 8, None), ("FUEL", 1, "81.60")], 21)
inbox["inbox-harbour-delivery"] = harbour_delivery(
    INBOX / "inbox-harbour-delivery.pdf", "DN-2026-1190", date(2026, 10, 1), "C-11502", LINDQ[:3], LINDQ[:3], "LA-2026-131",
    [("WBD-120", 2, 2), ("LMP-LED-02", 5, 3)], "Nordwind Logistics B.V.")
(INBOX / "expected.json").write_text(json.dumps(inbox, indent=2, ensure_ascii=False))
print("wrote the Nordwind invoices, the delivery notes, the letter and the inbox files")
