---
name: adm-pdf
description: >
  Works on PDFs inside ADM (APEX Document Management) from PL/SQL with adm_pdf_api: merge,
  split, watermark, text, image and comment overlays, page numbers, password protection, pages
  to images, form fields, attachments, convert to PDF and validate. Also digital signatures:
  signing keys (adm_signing_api), folder signing policy (adm_signing_policy_api), signing a
  PDF, and where a PDF comes from (get_provenance, adm_report_pdf_provenance_v). Use for "merge
  these PDFs", "watermark", "fill the form", "sign", or the hook AFTER_PDF_SIGNED. Needs APEX
  Office Print (AOP). Not for plain uploads (see adm-documents) or zip (see adm-zip).
metadata:
  version: "26.2"
---

# PDF operations and signing

Needs an established context and your own `commit` and `rollback` (see `adm-plsql`). Every
operation takes a **document id** and stores the result as a **new document**. The source does not
change. The work is done by AOP: without the setting `AOP_API_URL` an operation raises
`e_aop_not_configured`. The call waits for AOP, so it is synchronous.

## Gotchas

1. **Checks run before a file leaves the database**, in this order: view right on every source
   (`e_doc_not_found`, `e_no_permission`), edit right on the target folder, then the content:
   a PDF (`e_not_a_pdf`), total size up to the setting `PDF_MAX_FILE_SIZE_MB` (default 50,
   `e_limit_exceeded`), no password (`e_pdf_encrypted`), no digital signature (`e_pdf_signed`).
2. **A signed source is refused** by every operation that writes a new PDF (merge, split,
   watermark, protect, add_*, fill_form, flatten_form), because a change of one byte breaks the
   signature. Pass `p_invalidate_signatures => true` to make the result anyway. Read-only calls
   (`get_page_count`, `get_info`, `get_form_fields`, `get_attachments`, `validate`, `to_images`)
   work on a signed PDF. In a folder with signing mode `SIGN`, a source that ADM signed needs no `true` (not for `protect`, which is never auto-signed).
3. **Names are derived.** Without `p_document_name` the result is `report (watermarked).pdf`,
   `(merged)`, `(protected)`, `(text)`, `(image)`, `(comments)`, `(numbered)`, `(filled)`,
   `(flattened)`, `(attachments)`, `(signed)` or `(part 1)`. A used name gets a number:
   `report (watermarked) (2).pdf`. A name you pass that is used raises `e_doc_exists`, unless
   `p_overwrite => true`: then the result is a **new version** of that PDF, never merged into the
   latest version. `convert_to_pdf` only swaps the extension.
4. **`split`, `to_images` and `get_attachments` return many ids** (`apex_t_number`) and take
   no name or `p_overwrite`. `split` with no option gives one document per page (`p_pages_per_file`,
   `p_split_by_text`). `to_images` makes `report (page 1).jpg`.
5. **Every result runs the upload hooks** (`adm-hooks`). A hook that calls an operation on its own
   file loops (depth 10, `e_hook_depth_exceeded`): pass `p_run_hooks => false`. Only an
   administrator or the system user may (`e_admin_required`).
6. **Overlay positions are points** (1/72 inch) from the lower left corner. A4 is 595 x 842.
   `page` null means every page. `add_image` needs `width` or `height` (else `e_invalid_param`) and a
   PNG or JPEG document (else `e_not_supported`). One call takes up to 500 overlay items
   (`c_max_overlay_items`, `e_limit_exceeded`).
7. **`fill_form` checks your values first** against `get_form_fields` (name, type, option) and raises
   `e_invalid_param` naming the field, never the value. A check box sets `checked`, other fields
   set `value`. `flatten_form` turns fields into fixed content. `fill_form` appends to the file, so
   an old signature stays valid only for its old bytes.
8. **A failure of AOP** is `e_pdf_operation_failed` (`e_conversion_failed` for `convert_to_pdf`).
   Its text goes to the log, not the message. When another session takes the chosen name
   in between, `e_doc_exists` (or the unique index `ADM_DOCUMENTS_LIVE_NAME_UK`) is raised and nothing retries: roll back and call again.
9. **Embed sessions** need the grants `DOWNLOAD` (every source, also `get_info`, `validate`) and
   `UPLOAD` or `UPLOAD_VERSION` (the result), else `e_no_permission`. An embed session cannot call `sign`; auto-sign in a `SIGN` folder still applies.

## Recipes

Watermark, number the pages, merge. Replace the ids.

```sql
declare
  l_marked_id adm_documents.document_id%type;
  l_merged_id adm_documents.document_id%type;
  l_pages     pls_integer;
begin
  adm_context_api.system_user_login('JDOE');

  l_marked_id := adm_pdf_api.watermark(p_document_id => 1234, p_text => 'DRAFT');
  l_pages     := adm_pdf_api.get_page_count(p_document_id => l_marked_id);

  l_merged_id := adm_pdf_api.merge(
                   p_document_ids  => apex_t_number(1234, 1235)
                 , p_folder_id     => 42
                 , p_document_name => 'Bundle.pdf'
                 );
  commit;
end;
/
```

Put text on page 1 and read and fill a form:

```sql
declare
  l_texts  adm_pdf_api.t_text_overlays;
  l_fields adm_pdf_api.t_form_fields;
  l_values adm_pdf_api.t_form_values;
  l_doc_id adm_documents.document_id%type;
begin
  adm_context_api.system_user_login('JDOE');

  l_texts(1).page := 1;  l_texts(1).text := 'Approved';  l_texts(1).x := 72;  l_texts(1).y := 700;
  l_doc_id := adm_pdf_api.add_text(p_document_id => 1234, p_texts => l_texts);

  l_fields := adm_pdf_api.get_form_fields(p_document_id => 1236);   -- name, field_type, value, options
  l_values(1).name  := l_fields(1).name;
  l_values(1).value := 'Ada Lovelace';
  l_doc_id := adm_pdf_api.fill_form(p_document_id => 1236, p_values => l_values);
  commit;
end;
/
```

## Signing

**Keys.** `adm_signing_api.register_key` (administrator only) stores the address of a private key and
its certificate (RSA, at least 2048 bits, valid now). Providers: `TRANSIT` (OpenBao or Vault, needs an APEX
web credential), `OCI_VAULT`, and `DATABASE`, where the key sits encrypted in the ADM schema:
**not recommended**, anyone who runs code as the schema owner can sign with it. A user needs a grant
to sign, an administrator too: `grant_to_user`, `grant_to_group`. `list_usable_keys` lists what the
session may use. A disabled key or an expired certificate cannot sign.

```sql
declare
  l_signed_id adm_documents.document_id%type;
begin
  adm_context_api.system_user_login('JDOE');
  l_signed_id := adm_pdf_api.sign(
                   p_document_id    => 1234
                 , p_signing_key_id => 7
                 , p_reason         => 'Approved'
                 );   -- contract (signed).pdf, signature invisible unless p_field_name names a free field
  commit;
end;
/
```

`sign` needs AOP 26.1.2 or newer (`e_aop_too_old`), refuses an embed session
(`e_signing_not_in_embed`), a key without grant (`e_signing_key_denied`) and an unusable key
(`e_signing_key_unusable`). A source that is signed already is allowed: the new signature is added
(several signers in turn). A time stamp comes only when the setting `SIGNING_TSA_URL` is set.
The provider failing is `e_signing_failed`; ADM never stores a result with an invalid signature
(`e_signature_invalid`).

**Folder policy** (`adm_signing_policy_api`, administrator only): `create_policy(p_folder_path_pattern
=> '/contracts/', p_signing_mode => adm_signing_policy_api.c_mode_sign)`. The pattern is a lower-case path
prefix, the longest active one wins. Modes: `OFF` (PDFs not classified), `WATCH` (the default: record
where a PDF comes from), `SIGN` (also sign the results of operations in that folder and saves of the PDF editor
with the key of the setting `AUTO_SIGN_KEY_ID`, no grant needed). `SIGN` fails closed (`e_signing_key_unusable`,
`e_aop_too_old`, nothing is stored). `protect`, `sign`, `to_images` and `get_attachments` are not
auto-signed. A source with two or more valid signatures raises `e_auto_sign_multi_signed`. The hook
`AFTER_PDF_SIGNED` runs once per signed file (see `adm-hooks`). Folders without a policy use the
setting `AUTO_SIGN_DEFAULT_MODE`.

**Provenance.** `adm_pdf_api.get_provenance(p_document_id, p_version_id)` reads a stored status and no
file: `NOT_SIGNED`, `ADM_SIGNED` (all signatures are of an ADM key and valid, the last covers the whole
file), `MODIFIED` (an ADM signature, but the file changed), `FOREIGN_SIGNED` or `UNKNOWN` (null for a
non-PDF). `get_provenance_summary` is one line of text. `verify_signatures` checks digest and signature
(RSA only) per signature. It does **not** check trust in the certificate, revocation or the signing time.
`adm_pdf_provenance_api.backfill` (administrator) classifies versions stored before ADM kept the status. The
administrative view `adm_report_pdf_provenance_v` has one row per PDF version
(`pdf_provenance`, `previous_provenance`, `signing_mode`, `no_longer_pure_adm`) and ignores access rights.

## Errors

| Exception | Raised when |
| --- | --- |
| `e_aop_not_configured` | `AOP_API_URL` is empty |
| `e_not_a_pdf` / `e_not_supported` | source is no PDF / image or conversion type not supported |
| `e_pdf_encrypted` / `e_pdf_signed` | source needs a password / is signed (see gotcha 2) |
| `e_limit_exceeded` | file size, overlay count, form values or attachments over the limit |
| `e_invalid_param` | a value fails the check (field name, option, image size, overlay mix) |
| `e_pdf_operation_failed` / `e_conversion_failed` | AOP failed |
| `e_signing_key_not_found`, `e_signing_key_exists`, `e_signing_key_denied`, `e_signing_key_unusable` | unknown key, duplicate, no grant, disabled or expired |
| `e_signing_policy_not_found` / `e_signing_policy_exists` | policy id / pattern already has one |
| `e_admin_required` | a key or policy call by a non-administrator, or `p_run_hooks => false` |

Look up parameters with `select argument_name, data_type, in_out, defaulted from user_arguments
where package_name = 'ADM_PDF_API' and object_name = 'ADD_PAGE_NUMBERS'`, or read the API reference.
