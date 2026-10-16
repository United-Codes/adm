-- Lesson 3: adds two forms. The freight invoice of Nordwind Logistics is a second layout of the
-- document type invoice. The delivery note of Harbour Office Supplies is a new document type.
-- Run in SQLcl or SQL*Plus, connected as the ADM schema owner. Calls no model. Running it again
-- replaces both forms and the document type delivery_note.

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
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');

  -- Start over when the script runs again.
  <<form_loop>>
  for f in (select column_value as form_code from table(apex_t_varchar2('NORDWIND_INVOICE', 'HARBOUR_DELIVERY_NOTE'))) loop
    begin
      adm_ai_form_config_api.delete_form(adm_ai_form_config_api.get_form_id(l_profile_id, f.form_code));
    exception
      when adm_ai_error.e_form_not_found then
        null;
    end;
  end loop form_loop;
  begin
    adm_ai_form_config_api.delete_doc_type(adm_ai_form_config_api.get_doc_type_id(l_profile_id, 'delivery_note'));
  exception
    when adm_ai_error.e_form_doc_type_not_found then
      null;
  end;

  -- ---------------------------------------------------------------------------
  -- A second layout of an invoice
  -- ---------------------------------------------------------------------------
  l_form_id := adm_ai_form_config_api.create_form(
    p_profile_id  => l_profile_id
  , p_form_code   => 'NORDWIND_INVOICE'
  , p_doc_type_id => adm_ai_form_config_api.get_doc_type_id(l_profile_id, 'invoice')
  , p_description => 'a freight invoice of Nordwind Logistics B.V., Rotterdam'
  , p_config_json => q'~{
      "markers": ["VAT NL854122736B01", "^FREIGHT INVOICE$"],
      "field_patterns": {
        "invoice_number":         "^NWL/[0-9]{2}/[0-9]{5}$",
        "customer_number":        "^400-[0-9]{4}$",
        "invoice_date":           "^20[0-9]{2}-[01][0-9]-[0-3][0-9]$",
        "discount_amount":        "^[0-9.]+$",
        "line_items.item_number": "^[A-Z]{3,4}(-[A-Z]{3})?$"
      },
      "rules": [
        "The customer is the company under \"Invoice to:\".",
        "The customer number is the value of \"Account:\". The order reference is the value of \"Your PO:\"; \"n/a\" means there is none: return null.",
        "\"Shipment:\" is a shipment number of the carrier, not an order reference.",
        "Numbers use English format: \",\" groups thousands and \".\" is the decimal separator. \"1,234.56\" is 1234.56.",
        "Dates are printed like \"14 Mar 2026\".",
        "There is no discount: return 0.",
        "\"VAT 0% (reverse charge ...)\" means a VAT rate of 0."
      ]
    }~'
  );

  -- ---------------------------------------------------------------------------
  -- A new document type: the delivery note
  -- ---------------------------------------------------------------------------
  l_doc_type_id := adm_ai_form_config_api.create_doc_type(
    p_profile_id  => l_profile_id
  , p_doc_type    => 'delivery_note'
  , p_config_json => q'~{
      "json_schema": {
        "type": "object",
        "properties": {
          "delivery_note_number": {"type": "string"},
          "delivery_date":        {"type": "string", "description": "Date of the delivery as YYYY-MM-DD"},
          "customer_number":      {"type": "string", "description": "The number of the customer at the issuer"},
          "customer_name":        {"type": "string", "description": "Company name of the customer who ordered the goods"},
          "order_reference":      {"type": ["string", "null"], "description": "Order number of the customer, null if there is none"},
          "total_quantity":       {"type": "number", "description": "The printed total of the delivered quantities"},
          "line_items": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "item_number": {"type": "string"},
                "quantity":    {"type": "number", "description": "The delivered quantity"}
              },
              "required": ["item_number", "quantity"]
            }
          }
        },
        "required": ["delivery_note_number", "delivery_date", "customer_number", "customer_name",
                     "order_reference", "total_quantity", "line_items"]
      },
      "annotation_fields": ["delivery_note_number", "order_reference"],
      "line_checks": [
        {"name": "delivered quantity >= 0", "expr": "quantity >= 0"}
      ],
      "checks": [
        {"name": "sum of delivered quantities = total", "expr": "abs(sum_quantity - total_quantity) <= 0.01"}
      ]
    }~'
  );

  l_form_id := adm_ai_form_config_api.create_form(
    p_profile_id  => l_profile_id
  , p_form_code   => 'HARBOUR_DELIVERY_NOTE'
  , p_doc_type_id => l_doc_type_id
  , p_description => 'a delivery note of Harbour Office Supplies GmbH, Hamburg'
  , p_config_json => q'~{
      "markers": ["VAT ID DE 812 334 905", "^DELIVERY NOTE$"],
      "field_patterns": {
        "delivery_note_number":   "^DN-[0-9]{4}-[0-9]{4}$",
        "customer_number":        "^C-[0-9]{5}$",
        "delivery_date":          "^20[0-9]{2}-[01][0-9]-[0-3][0-9]$",
        "line_items.item_number": "^[A-Z]{3}-[A-Z0-9-]+$"
      },
      "decimal_comma": true,
      "rules": [
        "The customer is the company in the BILL TO block. The DELIVER TO block is only the shipping address.",
        "Dates are printed as DD.MM.YYYY.",
        "\"Your order\" holds the order reference.",
        "The line table has three quantities: Ordered, Delivered and Open. The quantity of a line is the Delivered column.",
        "The total quantity is the value of \"Total delivered\".",
        "The carrier is not the customer."
      ]
    }~'
  );
  commit;

  sys.dbms_output.put_line('forms NORDWIND_INVOICE and HARBOUR_DELIVERY_NOTE, document type delivery_note');
end;
/
