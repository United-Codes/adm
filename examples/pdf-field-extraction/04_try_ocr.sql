-- Lesson 4: reads the image harbour-invoice-12-scanned.png with the OCR service of settings.sql,
-- and extracts it as the text of the profile would. Run in SQLcl or SQL*Plus, connected as the ADM
-- schema owner. Needs the setting AI_TEXT_EXTRACTION = Y and pfx_ocr_provider in settings.sql.
--
-- The block adds the section ocr_text_extraction to the profile, reads the image, and then ROLLS
-- BACK: the profile and the documents stay as they are. Without the rollback, ADM would keep the
-- OCR text on the version of the image, and every later run would read the image from that text.
-- It sends the image to the OCR service and calls the text model at most once.
-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on

@@settings.sql

set define on
set verify off
set feedback off
set serveroutput on size unlimited
set linesize 200

declare
  l_profile_id number;
  l_document_id number;
  l_config     json_object_t;
  l_ocr        json_object_t := json_object_t();
  l_service    json_object_t := json_object_t();
  l_value      varchar2(4000 char);
  l_text       clob;
  l_result     json_object_t;
begin
  if '&pfx_ocr_provider' is null then
    sys.dbms_output.put_line('Set pfx_ocr_provider in settings.sql first.');
    return;
  end if;

  adm_context_api.system_user_login('&pfx_user');
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');
  l_config := json_object_t(adm_ai_form_config_api.get_profile_config(l_profile_id));

  -- The section ocr_text_extraction: the OCR service, and the file types that it reads.
  l_ocr.put('provider', '&pfx_ocr_provider');
  l_value := '&pfx_ocr_model';
  if l_value is not null then
    l_ocr.put('model', l_value);
  end if;
  l_value := '&pfx_ocr_credential';
  if l_value is not null then
    l_service.put('g_apex_web_credential', l_value);
  end if;
  l_value := '&pfx_ocr_base_url';
  if l_value is not null then
    l_service.put('g_base_url', l_value);
  end if;
  if l_service.get_size > 0 then
    l_ocr.put('config', l_service);
  end if;
  l_ocr.put('apply_to', json_object_t('{"mime_types": ["image/png"]}'));
  l_config.put('ocr_text_extraction', l_ocr);
  adm_ai_form_config_api.update_profile(p_profile_id => l_profile_id, p_config_json => l_config.to_clob);

  select d.document_id
    into l_document_id
    from adm_documents d
    join adm_folders f
      on f.folder_id = d.folder_id
   where f.folder_path = '&pfx_home/pfx_samples'
     and d.document_name = 'harbour-invoice-12-scanned.png';

  -- p_allow_ocr => true lets the call send the image to the OCR service.
  l_text := adm_ai_form_extract_api.document_text(l_document_id, l_profile_id, p_allow_ocr => true);
  sys.dbms_output.put_line('--- The OCR text (the first 700 characters)');
  sys.dbms_output.put_line(substr(l_text, 1, 700));

  l_result := adm_ai_form_extract_api.extract(l_profile_id, l_document_id);
  sys.dbms_output.put_line('--- The result');
  sys.dbms_output.put_line(l_result.to_string);

  rollback; -- @dblinter ignore(g-3310): the block must leave no OCR text on the version
end;
/
