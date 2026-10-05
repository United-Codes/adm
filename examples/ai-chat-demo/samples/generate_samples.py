#!/usr/bin/env python3
"""Generates the sample PDFs of the "Ask questions across your documents" course.

Every company, person and number is invented. Mail domains use .example, so the files are safe
to send to a model provider. The files are small on purpose: one or two pages each, so the whole
set embeds for a fraction of a cent.

The PDFs are committed next to this script; run it only to change them:

    python3 -m venv .venv && .venv/bin/pip install reportlab
    .venv/bin/python generate_samples.py

The scanned amendment needs `pdftoppm` (poppler) and `magick` (ImageMagick).

manifest.csv says where each file goes and who may see it:
  corpus      contracts | policies   (which RAG collection reads it)
  legal       Y = visible to the Legal user (AIC_LEGAL)
  hr          Y = visible to the HR user (AIC_HR)
  scanned     Y = image only, no text layer
"""
import subprocess
import tempfile
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

OUT = Path(__file__).parent / "pdf"
OUT.mkdir(exist_ok=True)
S = getSampleStyleSheet()
BODY, H1, H2 = S["BodyText"], S["Heading1"], S["Heading2"]

# (file name, corpus, legal sees it, hr sees it, scanned, note)
MANIFEST = [
    ("contract_nordlicht_supply.pdf", "contracts", "Y", "Y", "N", "supply agreement, notice period 90 days"),
    ("contract_alpenwerk_maintenance.pdf", "contracts", "Y", "Y", "N", "maintenance contract, notice period 30 days"),
    ("contract_ferrotek_framework.pdf", "contracts", "Y", "Y", "N", "framework agreement, notice period 6 months"),
    ("contract_helios_distribution.pdf", "contracts", "Y", "N", "N", "exclusive distribution, notice 12 months, Legal only"),
    ("scan_nordlicht_amendment.pdf", "contracts", "Y", "Y", "Y", "scanned amendment: notice period 90 -> 120 days"),
    ("travel_policy_2025.pdf", "policies", "Y", "Y", "N", "travel policy, valid until 2025-12-31"),
    ("travel_policy_2026.pdf", "policies", "Y", "Y", "N", "travel policy, valid from 2026-01-01, other numbers"),
    ("remote_work_policy.pdf", "policies", "Y", "Y", "N", "remote work, 2 weeks notice for the arrangement"),
    ("employee_handbook.pdf", "policies", "Y", "Y", "N", "handbook, employee notice periods"),
    ("salary_bands.pdf", "policies", "N", "Y", "N", "salary bands, HR only"),
]


def build(name, story):
    SimpleDocTemplate(str(OUT / name), pagesize=A4, leftMargin=22 * mm, rightMargin=22 * mm,
                      topMargin=20 * mm, bottomMargin=20 * mm, title=name, author="Sample set").build(story)


def p(text, style=BODY):
    return Paragraph(text, style)


def table(rows, widths):
    t = Table(rows, colWidths=widths)
    t.setStyle(TableStyle([("FONTSIZE", (0, 0), (-1, -1), 9), ("VALIGN", (0, 0), (-1, -1), "TOP"),
                           ("LINEBELOW", (0, 0), (-1, 0), 0.6, colors.black)]))
    return t


def clauses(items):
    story = []
    for title, text in items:
        story += [p(f"<b>{title}</b>"), p(text), Spacer(1, 3 * mm)]
    return story


def contracts():
    build("contract_nordlicht_supply.pdf", [
        p("Supply Agreement L-2024-017", H1),
        p("between <b>Nordlicht Verpackung GmbH</b>, Seeallee 4, 20000 Beispielhafen (the Supplier) and "
          "<b>Example Works GmbH</b>, Hammerweg 12, 90000 Musterstadt (the Customer)."),
        Spacer(1, 5 * mm),
    ] + clauses([
        ("1. Subject", "The Supplier delivers corrugated packaging in the sizes listed in Annex A. "
                       "The Customer orders by purchase order. Delivery is free to the Customer's plant."),
        ("2. Term", "This Agreement starts on 1 January 2025 and runs for three years. After that it renews "
                    "for periods of one year unless one party terminates it under clause 4."),
        ("3. Prices", "Prices are fixed for the first 18 months. After that the Supplier may adjust them once a "
                      "year by at most 2 percent. Payment is due 30 days after the invoice date."),
        ("4. Termination", "Either party may terminate this Agreement with a notice period of 90 days to the "
                           "end of a calendar quarter. The notice must be in writing. Termination for good "
                           "cause stays possible at any time."),
        ("5. Liability", "The liability of each party is limited to the value of the goods ordered in the "
                         "calendar year in which the damage happened. This does not apply to intent or gross "
                         "negligence."),
        ("6. Governing law", "German law applies. The court of Beispielhafen has jurisdiction."),
    ]))

    build("contract_alpenwerk_maintenance.pdf", [
        p("Maintenance Contract M-2025-203", H1),
        p("between <b>Alpenwerk Anlagenservice AG</b>, Passstrasse 8, 80000 Beispieltal (the Contractor) and "
          "<b>Example Works GmbH</b> (the Customer)."),
        Spacer(1, 5 * mm),
    ] + clauses([
        ("1. Scope", "The Contractor services the three packing lines at the Musterstadt plant: one inspection "
                     "each quarter, spare parts at list price minus 10 percent."),
        ("2. Response times", "The Contractor responds to a fault report within 4 working hours and is on site "
                              "within 2 working days."),
        ("3. Fee", "The yearly fee is EUR 18,400 plus VAT, invoiced in four equal quarterly parts."),
        ("4. Termination", "Either party may terminate this Contract with a notice period of 30 days to the "
                           "end of a calendar month. The notice must be in writing."),
        ("5. Liability", "The liability of the Contractor is limited to EUR 250,000 per event."),
    ]))

    build("contract_ferrotek_framework.pdf", [
        p("Framework Agreement R-2023-088", H1),
        p("between <b>Ferrotek Metallbau GmbH</b>, Hammerweg 12, 90000 Musterstadt (Ferrotek) and "
          "<b>Example Works GmbH</b> (the Buyer)."),
        Spacer(1, 5 * mm),
    ] + clauses([
        ("1. Purpose", "This framework agreement governs all individual orders of steel brackets and mounting "
                       "plates that the Buyer places with Ferrotek. Each order is a separate contract."),
        ("2. Minimum volume", "The Buyer orders goods worth at least EUR 40,000 in each calendar year. "
                              "If the Buyer orders less, Ferrotek may invoice the difference at 20 percent."),
        ("3. Confidentiality", "Both parties keep the other party's drawings and prices confidential for five "
                               "years after this agreement ends."),
        ("4. Termination", "Either party may terminate this agreement with a notice period of six months to the "
                           "end of a calendar year. Orders already confirmed stay valid until they are fulfilled."),
        ("5. Governing law", "German law applies."),
    ]))

    build("contract_helios_distribution.pdf", [
        p("CONFIDENTIAL - Legal department only", H2),
        p("Exclusive Distribution Agreement D-2026-004", H1),
        p("between <b>Example Works GmbH</b> (the Principal) and <b>Helios Handelsgesellschaft mbH</b>, "
          "Sonnenring 2, 70000 Beispielstadt (the Distributor)."),
        Spacer(1, 5 * mm),
    ] + clauses([
        ("1. Exclusivity", "The Distributor is the only reseller of the Principal's products in Austria and "
                           "Switzerland. The Principal does not appoint another reseller there."),
        ("2. Minimum sales", "The Distributor sells at least 1,200 units per year. If it sells fewer in two "
                             "years in a row, the Principal may end the exclusivity."),
        ("3. Termination", "Either party may terminate this Agreement with a notice period of twelve months to "
                           "the end of a calendar year. During the notice period the exclusivity stays in force."),
        ("4. Liability", "The liability of the Principal is limited to EUR 2,000,000 in total. The Distributor "
                         "carries the product liability insurance for all units it sells."),
        ("5. Governing law", "Austrian law applies. The court of Vienna has jurisdiction."),
    ]))


def scanned_amendment():
    """An amendment printed to a page, then made a slightly skewed, noisy image-only PDF."""
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "source.pdf"
        SimpleDocTemplate(str(src), pagesize=A4, leftMargin=25 * mm, rightMargin=25 * mm, topMargin=25 * mm,
                          bottomMargin=25 * mm).build([
            p("Amendment No. 1 to Supply Agreement L-2024-017", H1),
            p("between Nordlicht Verpackung GmbH and Example Works GmbH"),
            Spacer(1, 6 * mm),
            p("The parties agree that clause 4 (Termination) of the Supply Agreement is changed as follows:"),
            Spacer(1, 3 * mm),
            p("<b>4. Termination.</b> Either party may terminate this Agreement with a notice period of "
              "<b>120 days</b> to the end of a calendar quarter. The notice must be in writing."),
            Spacer(1, 3 * mm),
            p("All other clauses stay in force. This amendment takes effect on 1 October 2026."),
            Spacer(1, 14 * mm),
            p("Beispielhafen, 2026 &nbsp;&nbsp;&nbsp; ______________ &nbsp;&nbsp;&nbsp; ______________"),
        ])
        png = Path(tmp) / "page.png"
        subprocess.run(["pdftoppm", "-r", "130", "-png", "-singlefile", str(src), str(png.with_suffix(""))], check=True)
        subprocess.run(["magick", str(png), "-colorspace", "Gray", "-background", "white", "-rotate", "0.8",
                        "-attenuate", "0.12", "+noise", "Gaussian", "-blur", "0x0.5", "-level", "12%,88%",
                        "-density", "130", str(OUT / "scan_nordlicht_amendment.pdf")], check=True)


def policies():
    build("travel_policy_2025.pdf", [
        p("Travel Policy 2025", H1),
        p("Valid until 31 December 2025. Applies to all employees of Example Works GmbH."),
        Spacer(1, 5 * mm),
        table([["Item", "Limit"],
               ["Hotel, per night, large cities", "EUR 140"],
               ["Hotel, per night, other places", "EUR 110"],
               ["Meals, per day of travel", "EUR 28"],
               ["Own car, per kilometre", "EUR 0.30"]], [90 * mm, 50 * mm]),
        Spacer(1, 5 * mm),
    ] + clauses([
        ("Flights", "Book economy class. The travel desk books flights at least 14 days ahead where possible."),
        ("Approval", "A trip that costs more than EUR 500 needs the approval of the line manager before booking."),
        ("Expense claims", "Submit the expense claim within 30 days after the trip."),
    ]))

    build("travel_policy_2026.pdf", [
        p("Travel Policy 2026", H1),
        p("Valid from 1 January 2026. This version replaces the Travel Policy 2025. "
          "Applies to all employees of Example Works GmbH."),
        Spacer(1, 5 * mm),
        table([["Item", "Limit"],
               ["Hotel, per night, large cities", "EUR 165"],
               ["Hotel, per night, other places", "EUR 120"],
               ["Meals, per day of travel", "EUR 32"],
               ["Own car, per kilometre", "EUR 0.35"]], [90 * mm, 50 * mm]),
        Spacer(1, 5 * mm),
    ] + clauses([
        ("Flights", "Book economy class for flights up to six hours. For longer flights you may book premium "
                    "economy. The travel desk books flights at least 14 days ahead where possible."),
        ("Approval", "A trip that costs more than EUR 750 needs the approval of the line manager before booking."),
        ("Expense claims", "Submit the expense claim within 30 days after the trip."),
    ]))

    build("remote_work_policy.pdf", [
        p("Remote Work Policy", H1),
        p("Applies to all employees of Example Works GmbH whose job allows it."),
        Spacer(1, 5 * mm),
    ] + clauses([
        ("1. Remote days", "Employees may work remotely up to three days per week. Teams agree the days so that "
                           "every team is in the office on Tuesdays and Thursdays."),
        ("2. Core hours", "Everybody is reachable between 10:00 and 15:00 on remote days."),
        ("3. Equipment", "The company pays a one-time allowance of EUR 300 for a desk chair or a monitor. "
                         "Laptops and headsets come from IT."),
        ("4. Ending the arrangement", "The remote work arrangement can be ended by the employee or by the "
                                      "company with two weeks' notice. This is not a termination of the "
                                      "employment."),
    ]))

    build("employee_handbook.pdf", [
        p("Employee Handbook", H1),
        p("Example Works GmbH. Page 1 of 2."),
        Spacer(1, 5 * mm),
    ] + clauses([
        ("Working hours", "The regular working week has 38 hours. Overtime is compensated with time off."),
        ("Vacation", "Full-time employees have 28 days of paid vacation per year. Unused days up to 5 days may "
                     "be carried over until 31 March of the following year."),
        ("Sick leave", "Tell your manager before 09:00 on the first day. A medical certificate is needed from "
                       "the third day."),
    ]) + [PageBreak(), p("Employee Handbook - page 2 of 2", H2)] + clauses([
        ("Probation", "The probation period is six months. During probation an employee can resign, and the "
                      "company can dismiss, with two weeks' notice."),
        ("Notice periods after probation", "After probation the notice period for an employee who resigns is four "
                                           "weeks to the 15th or to the end of a calendar month. The company's "
                                           "notice period grows with the years of service: two months after five "
                                           "years, four months after ten years."),
        ("Expense claims", "Submit expense claims within 30 days. See the Travel Policy for the limits."),
    ]))

    build("salary_bands.pdf", [
        p("CONFIDENTIAL - HR only", H2),
        p("Salary Bands 2026", H1),
        p("Gross yearly salary in EUR for full-time employees."),
        Spacer(1, 5 * mm),
        table([["Band", "Role examples", "From", "To"],
               ["B1", "Assistant, junior clerk", "34,000", "42,000"],
               ["B2", "Clerk, technician", "42,000", "54,000"],
               ["B3", "Engineer, team lead", "54,000", "72,000"],
               ["B4", "Senior engineer, department lead", "72,000", "95,000"],
               ["B5", "Director", "95,000", "130,000"]], [20 * mm, 70 * mm, 25 * mm, 25 * mm]),
        Spacer(1, 5 * mm),
        p("A senior engineer is placed in band B4. Moves between bands need the approval of the HR director."),
    ])


if __name__ == "__main__":
    contracts(); scanned_amendment(); policies()
    with open(Path(__file__).parent / "manifest.csv", "w") as f:
        f.write("file_name,corpus,legal,hr,scanned,note\n")
        for row in MANIFEST:
            f.write(",".join('"' + c + '"' if "," in c else c for c in row) + "\n")
    for name, *_ in MANIFEST:
        print(f"{(OUT / name).stat().st_size:>8}  {name}")
