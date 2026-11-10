---
name: adm-ai-form-extraction
description: >
  Extracts the data of forms (invoices, delivery notes) from PDFs and images in ADM (APEX
  Document Management) with a language model, using the AI Pack: profiles, document types and
  forms (adm_ai_form_config_api), extraction, review and approval (adm_ai_form_extract_api),
  results in adm_my_form_extractions_v, the hook AFTER_FORM_EXTRACTION, and the OCR fallback for
  scans. Use for "read the invoice fields", "extract data from PDFs", "check the totals" or
  "approve an extraction". AI Pack only; it needs the uc_ai library and a model provider. Not
  for RAG question answering (see adm-ai-rag) and not for PDF edits (see adm-pdf).
metadata:
  version: "26.2"
---

# Form extraction (AI Pack)

Needs an established context and your own `commit` (see `adm-plsql`). Every `adm_ai_form_config_api`
call needs an **administrator**. `adm_ai_form_admin_api` is the JSON server side of the manager
region (read calls return JSON text): use it only to build a screen, otherwise use the two APIs above.
Never write the `config_json` columns directly: the packages validate them.

## Gotchas

1. **Three levels, three JSON configurations.** A **profile** selects the documents
   (`source_folder_path` or `source_file_annotation_key`, as for a RAG collection) and the models (`text_model`,
   optional `vision_model`: `provider`, `model`, `config` as UC AI names them). A **document type** holds
   the fields as `json_schema` (line items are its array property `line_items`) and the `checks`. A
   **form** is one layout of one issuer, found by `markers`. Each `create_*` returns the id; the
   `get_*_id` calls look it up by name or code. The profile name is lower case letters, digits, `_` and `-`.
2. **The model never picks the form of a text document.** All `markers` of an active form (regular
   expressions, `^` and `$` match at each line) must match the text. No form or more than one
   goes to `REVIEW`. Test them with `matching_forms(p_profile_id, adm_ai_form_extract_api.document_text(...))`.
3. **Checks are SQL conditions, whitelisted.** `checks` see the scalar fields and `line_count`,
   `sum_<col>`, `min_<col>`, `max_<col>`; `line_checks` run per line. Allowed: field names, numbers,
   quoted strings, `+ - * / ( ) , = <> != < <= > >=`, `and or not is null between in` and
   `abs round trunc sign nvl coalesce greatest least mod`. Anything else raises `e_form_expression`.
   A regex that does not compile is `e_form_regex`; a field the schema lacks is `e_form_unknown_field`.
   Before the checks, every result must fit the `json_schema`: required keys present (null or blank
   only when the type allows `"null"`), `string`/`number`/`integer`/`boolean` types, `enum` values,
   and each line an object. A misfit is an issue, so the result goes to `REVIEW`.
   A schema with `line_items` sends an empty table to `REVIEW` (`no line items`) unless the doc
   type sets `"allow_empty_line_items": true`; then the checks run with `line_count` 0 and the
   aggregates null, so write them with `nvl(sum_<col>, 0)`.
4. **Status.** `OK` (every check passed), `REVIEW` (a person must look; one line per issue in `issues`),
   `FAILED` (an error), `APPROVED`. Too little text (`min_text_chars`, default 20: a scan) goes to
   review **without a model call**, as does text over `max_text_chars` (no default: without it there is no limit).
5. **`extract` writes nothing, `extract_document` writes and publishes.** `extract_document` stores one row
   per profile and document, sets the annotations `<doc_type>.<field>` (for `annotation_fields`) and removes
   the `review_tag` (default `extraction-review`) for `OK` and `APPROVED`, and does the opposite
   otherwise. It needs the **edit** right and a document in the profile's scope (`e_form_out_of_scope`).
   It does not wait for OCR: a scan not read yet gets method `NONE`.
6. **`approve` re-checks the corrected values** and raises `e_form_checks_failed` or `e_form_unknown_field`
   and changes nothing. A result read from an older version raises `e_form_extraction_stale`: extract
   again. `p_corrections` holds only the changed fields, `p_line_items` all line items.
   `p_add_to_test_set` (default true) copies the result to the test set that `measure` runs on.
7. **The hook `AFTER_FORM_EXTRACTION` runs for `OK` and `APPROVED`** with `:p_document_id`,
   `:p_version_id`, `:p_profile_id`, `:p_extraction_id`, `:p_status`. A hook error does
   not reach the caller of `extract_document`: the row becomes `FAILED`. A refusal (-20700 .. -20999) keeps its
   own message as the issue, and any other error is written as a sentence.
   For `approve` the error is raised and nothing changes.
8. **Automatic processing:** with `"process_new_documents": true` the AI queue job extracts new documents
   (at most `max_documents_per_run`, default 20), as the system user, committing after each. A failure
   becomes `FAILED` and counts against the attempt budget. `start_processing` in the admin API runs it now.
9. **Text comes from OCR text stored on the version, else the built-in filter**, else (only with
   `p_allow_ocr => true`) the `ocr_text_extraction` of the profile. A scan without text layer is read
   by the global OCR fallback (`adm_ai_ocr_fallback_api`) when the setting `AI_OCR_FALLBACK_CONFIG`
   holds a JSON configuration and `AI_TEXT_EXTRACTION` is `Y`. The setting **ships empty**: OCR sends the file to an
   external service, so it is off until the customer chooses a provider. Keep the profile's
   `min_text_chars` at or below the fallback's (default 20).
10. **Images** go to the `vision_model` (no model: review) unless `ocr_text_extraction.apply_to.mime_types`
    names their type. A model call and OCR write an `AI_READ_DOCUMENT` audit row for a user.
    A form with `"model_input": "file"` (default `text`) is still found by its markers, but sends the file
    to the `vision_model` to read the values (method `FILE`): for grids with empty cells and check boxes,
    whose layout the text loses. It needs a `vision_model` of `openai`, `anthropic`, `google`, `oci`,
    `mistral` or `responses_api` (not `ollama`) and no `line_pattern`; `update_profile` refuses to break
    such a form. Only PDFs and `image/*` up to the profile's `max_file_bytes` (default 20 MB) are sent;
    other files go to `REVIEW` without a call.
11. **No procedure commits.** `start_processing` and `start_measurement` create a scheduler job in an
    autonomous transaction.

## Recipes

A profile, a document type and a form (a minimal invoice; replace the folder path):

```sql
declare
  l_profile_id  number;
  l_doc_type_id number;
  l_form_id     number;
begin
  adm_context_api.system_user_login('ADMIN');

  l_profile_id := adm_ai_form_config_api.create_profile(
    p_profile_name => 'supplier_invoices'
  , p_config_json  => q'~{
      "source_folder_path": "/users/admin/inbox",
      "text_model": {"provider": "openai", "model": "gpt-5.6-luna",
                     "config": {"g_apex_web_credential": "OPENAI"}},
      "rules": ["Return dates as YYYY-MM-DD.", "If a value is missing, return null. Never guess."]
    }~');

  l_doc_type_id := adm_ai_form_config_api.create_doc_type(
    p_profile_id  => l_profile_id
  , p_doc_type    => 'invoice'
  , p_config_json => q'~{
      "json_schema": {"type": "object", "properties": {
        "invoice_number": {"type": "string"}, "net_amount": {"type": "number"},
        "vat_amount": {"type": "number"}, "total_amount": {"type": "number"}}},
      "annotation_fields": ["invoice_number", "total_amount"],
      "checks": [{"name": "net + VAT = total",
                  "expr": "abs(net_amount + vat_amount - total_amount) <= 0.01"}]
    }~');

  l_form_id := adm_ai_form_config_api.create_form(
    p_profile_id  => l_profile_id
  , p_form_code   => 'ACME_INVOICE'
  , p_doc_type_id => l_doc_type_id
  , p_description => 'an invoice of Acme GmbH'
  , p_config_json => q'~{"markers": ["VAT ID DE 123 456 789"],
                         "field_patterns": {"invoice_number": "^INV-[0-9]{5}$"}}~');
  commit;
end;
/
```

Extract one document, then approve a correction (this calls the model; replace the ids):

```sql
begin
  adm_context_api.system_user_login('ADMIN');
  adm_ai_form_extract_api.extract_document(p_profile_id => 1, p_document_id => 1234);
  adm_ai_form_extract_api.approve(
    p_profile_id  => 1
  , p_document_id => 1234
  , p_corrections => '{"total_amount": 285.24}'
  );
  commit;
end;
/
```

Read the results as a user. The view is session scoped and follows `adm_my_documents_v`: a profile
grants no right of its own. Fields are JSON (add `returning number` inside `json_value` for a number).
Filter on `status in ('OK', 'APPROVED')` for accepted values.

```sql
select x.document_name, x.status, x.form_code, x.issues
     , json_value(x.fields, '$.total_amount') as total_amount
  from adm_my_form_extractions_v x
 where x.profile_name = 'supplier_invoices'
   and x.status in ('OK', 'APPROVED');
```

The view also has `doc_type`, `method` (`TEXT`, `IMAGE`, `FILE`, `NONE`), `text_source` (`FILTER`, `OCR`),
`line_items`, `model`, token counts, `seconds`, `reviewed_by`. The administrative view
`adm_ai_form_profile_status_v` counts results by status per profile (`ok_count`, `review_count`,
`failed_count`, `approved_count`, `test_case_count`) and ignores access rights.

**Measure before you trust it.** `set_expected` stores a known-good result as a test case. `measure(p_profile_id,
p_label)` runs the pipeline over the test set (model calls, `p_model` and `p_vision_model` override) and stores
the rows under the label. Each test case is measured on the version it was stored for, and compared by
the declared type (numbers to 0.005, integers exactly). `delete_measurement` removes them.

## Errors

| Exception (`adm_ai_error.`) | Raised when |
| --- | --- |
| `e_form_profile_not_found`, `e_form_doc_type_not_found`, `e_form_not_found` | unknown profile, type or form |
| `e_form_extraction_not_found` | a document has no result in the profile (approve) |
| `e_config_invalid` / `e_config_missing` | the JSON configuration is wrong or lacks a key |
| `e_form_expression` / `e_form_regex` / `e_form_unknown_field` | a check, a pattern or a field name is wrong |
| `e_form_checks_failed` | approved values fail the checks (issues in the message) |
| `e_form_extraction_stale` | the result is of an older version |
| `e_form_out_of_scope` | the document is not in the profile's folder or annotation scope |
| `e_form_doc_type_in_use` | a type still has forms |
| `e_form_job_refused` | a background run cannot start (already running, empty test set) |

Look up parameters with `select argument_name, data_type, in_out, defaulted from user_arguments
where package_name = 'ADM_AI_FORM_EXTRACT_API' and object_name = 'MEASURE'`, or read the AI Pack API reference.
