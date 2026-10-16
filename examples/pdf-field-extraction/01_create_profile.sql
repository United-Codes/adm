-- Lesson 1: creates the form extraction profile pfx_supplier_forms with the document type invoice
-- and the form HARBOUR_INVOICE. Run in SQLcl or SQL*Plus, connected as the ADM schema owner, after
-- 00_load_samples.sql. Calls no model.
--
-- Running it again starts over: it deletes the profile first, and with it every result, test case
-- and measurement of the profile.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

@@settings.sql

set define on
set verify off
set feedback off
set serveroutput on

declare
  l_profile_id  number;
  l_doc_type_id number;
  l_form_id     number;
begin
  adm_context_api.system_user_login('&pfx_user');

  begin
    adm_ai_form_config_api.delete_profile(adm_ai_form_config_api.get_profile_id('pfx_supplier_forms'));
  exception
    when adm_ai_error.e_form_profile_not_found then
      null;
  end;

  -- ---------------------------------------------------------------------------
  -- The profile
  -- ---------------------------------------------------------------------------
  l_profile_id := adm_ai_form_config_api.create_profile(
    p_profile_name => 'pfx_supplier_forms'
  , p_description  => 'Course "Extract data from PDF forms": forms of Harbour Office Supplies and Nordwind Logistics'
  , p_config_json  => q'~{
      "source_folder_path": "&pfx_home/pfx_samples",
      "text_model": {
        "provider": "ollama",
        "model": "&pfx_text_model",
        "config": {
          "g_base_url": "&pfx_base_url",
          "g_apex_web_credential": "&pfx_credential",
          "g_extra_body": {"options": {"temperature": 0, "num_ctx": 16384}},
          "ollama": {"g_use_responses_api": false}
        }
      },
      "max_text_chars": 20000,
      "rules": [
        "Return dates as YYYY-MM-DD.",
        "If a value is not in the document, return null. Never guess.",
        "Take every value from this document. Numbers in notes or in the payment text that refer to other documents are not values of this document."
      ]
    }~'
  );

  -- ---------------------------------------------------------------------------
  -- The document type invoice
  -- ---------------------------------------------------------------------------
  l_doc_type_id := adm_ai_form_config_api.create_doc_type(
    p_profile_id  => l_profile_id
  , p_doc_type    => 'invoice'
  , p_config_json => q'~{
      "json_schema": {
        "type": "object",
        "properties": {
          "document_type":   {"type": "string", "enum": ["invoice", "credit_note"]},
          "invoice_number":  {"type": "string"},
          "invoice_date":    {"type": "string", "description": "Date of the document as YYYY-MM-DD"},
          "due_date":        {"type": ["string", "null"], "description": "Due date as YYYY-MM-DD, null if there is none"},
          "customer_number": {"type": "string", "description": "The number of the customer at the issuer"},
          "customer_name":   {"type": "string", "description": "Company name of the customer who receives the invoice"},
          "order_reference": {"type": ["string", "null"], "description": "Order number of the customer, null if there is none"},
          "discount_amount": {"type": "number", "description": "Discount in the totals block as a positive number, 0 if there is none"},
          "net_amount":      {"type": "number"},
          "vat_rate":        {"type": "number", "description": "VAT rate in percent, for example 19"},
          "vat_amount":      {"type": "number"},
          "total_amount":    {"type": "number"},
          "line_items": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "item_number": {"type": "string"},
                "quantity":    {"type": "number"},
                "unit_price":  {"type": "number"},
                "amount":      {"type": "number"}
              },
              "required": ["item_number", "quantity", "unit_price", "amount"]
            }
          }
        },
        "required": ["document_type", "invoice_number", "invoice_date", "due_date", "customer_number",
                     "customer_name", "order_reference", "discount_amount", "net_amount", "vat_rate",
                     "vat_amount", "total_amount", "line_items"]
      },
      "annotation_fields": ["invoice_number", "customer_number", "total_amount"],
      "rules": [
        "The issuer of the invoice is never the customer.",
        "A credit note has no due date: return null. Its amounts are negative; keep the sign."
      ]
    }~'
  );

  -- ---------------------------------------------------------------------------
  -- The form HARBOUR_INVOICE
  -- ---------------------------------------------------------------------------
  l_form_id := adm_ai_form_config_api.create_form( -- @dblinter ignore(g-2135): the script needs no id of the form, create_form returns it anyway
    p_profile_id  => l_profile_id
  , p_form_code   => 'HARBOUR_INVOICE'
  , p_doc_type_id => l_doc_type_id
  , p_description => 'an invoice or credit note of Harbour Office Supplies GmbH, Hamburg'
  , p_config_json => q'~{
      "markers": ["VAT ID DE 812 334 905", "^(INVOICE|CREDIT NOTE)$"],
      "field_patterns": {
        "invoice_number":  "^(INV-[0-9]{4}-[0-9]{5}|CN-[0-9]{4}-[0-9]{4})$",
        "customer_number": "^C-[0-9]{5}$",
        "invoice_date":    "^20[0-9]{2}-[01][0-9]-[0-3][0-9]$"
      },
      "line_pattern": "^([0-9]{1,3})\\n([A-Z]{3}-[A-Z0-9-]+)\\n(.*)\\n([0-9,]+)\\n([0-9.]+,[0-9]{2})\\n(-?[0-9.]+,[0-9]{2})$",
      "line_columns": {"item_number": 2, "quantity": 4, "unit_price": 5, "amount": 6},
      "decimal_comma": true,
      "rules": [
        "The customer is the company in the BILL TO block. The DELIVER TO block is only the shipping address.",
        "Numbers use German format: \".\" groups thousands and \",\" is the decimal separator. \"1.234,56\" is 1234.56.",
        "Dates are printed as DD.MM.YYYY.",
        "\"Your order\" holds the order reference. \"-\" means there is none: return null.",
        "\"Carried forward\" and \"Brought forward\" rows are page subtotals, not line items."
      ]
    }~'
  );
  commit;

  sys.dbms_output.put_line('profile pfx_supplier_forms: document type invoice, form HARBOUR_INVOICE');
end;
/
