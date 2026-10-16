-- Lesson 3: prints the text that ADM extracts from a sample document, the text that the markers
-- and the model see. Calls no model.
--
--   @03_show_text.sql nordwind-invoice-01-standard.pdf

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

@@settings.sql

set define on
set verify off
set feedback off
set serveroutput on size unlimited

begin
  adm_context_api.system_user_login('&pfx_user');
  <<document_loop>>
  for d in (
    select document_id
      from adm_my_documents_v
     where folder_path = '&pfx_home/pfx_samples'
       and document_name = '&1'
  ) loop
    sys.dbms_output.put_line(adm_ai_form_extract_api.document_text(d.document_id));
  end loop document_loop;
end;
/

undefine 1
