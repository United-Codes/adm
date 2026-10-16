-- Lesson 1: takes one invoice of the form HARBOUR_INVOICE through the extraction, one step at a
-- time, writes the result and prints it. Run in SQLcl or SQL*Plus, connected as the ADM schema
-- owner, after 01_create_profile.sql. It makes one model call.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

@@settings.sql

set define on
set verify off
set feedback off
set serveroutput on size unlimited
set linesize 200

define pfx_document = 'harbour-invoice-01-standard.pdf'

-- The ADM context stays for the session: the views adm_my_* below show what this user may view.
begin
  adm_context_api.system_user_login('&pfx_user');
end;
/

-- ---------------------------------------------------------------------------
-- Read the text of the invoice
-- ---------------------------------------------------------------------------
declare
  l_lines apex_t_varchar2;
begin
  <<document_loop>>
  for d in (
    select document_id
      from adm_my_documents_v
     where folder_path = '&pfx_home/pfx_samples'
       and document_name = '&pfx_document'
  ) loop
    l_lines := apex_string.split(adm_ai_form_extract_api.document_text(d.document_id), chr(10));
    sys.dbms_output.put_line('The first 20 of ' || l_lines.count || ' lines:');
    <<line_loop>>
    for i in 1 .. least(20, l_lines.count) loop
      sys.dbms_output.put_line('  ' || l_lines(i));
    end loop line_loop;
  end loop document_loop;
end;
/

-- ---------------------------------------------------------------------------
-- Find the form of the invoice
-- ---------------------------------------------------------------------------
declare
  l_profile_id number;
  l_forms      apex_t_varchar2;
begin
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');
  <<document_loop>>
  for d in (
    select document_id
      from adm_my_documents_v
     where folder_path = '&pfx_home/pfx_samples'
       and document_name = '&pfx_document'
  ) loop
    l_forms := adm_ai_form_extract_api.matching_forms(
                 p_profile_id => l_profile_id
               , p_text       => adm_ai_form_extract_api.document_text(d.document_id)
               );
    sys.dbms_output.put_line('Forms whose markers match: ' || apex_string.join(l_forms, ', '));
    sys.dbms_output.put_line('System prompt of the form:');
    sys.dbms_output.put_line(adm_ai_form_extract_api.system_prompt(
                               adm_ai_form_config_api.get_form_id(l_profile_id, l_forms(1))
                             ));
  end loop document_loop;
end;
/

-- ---------------------------------------------------------------------------
-- Extract the invoice
-- ---------------------------------------------------------------------------
begin
  <<document_loop>>
  for d in (
    select document_id
      from adm_my_documents_v
     where folder_path = '&pfx_home/pfx_samples'
       and document_name = '&pfx_document'
  ) loop
    adm_ai_form_extract_api.extract_document(
      p_profile_id  => adm_ai_form_config_api.get_profile_id('pfx_supplier_forms')
    , p_document_id => d.document_id
    );
  end loop document_loop;
  commit;
end;
/

declare
  l_lines json_array_t;
begin
  <<result_loop>>
  for x in (
    select x.status
         , x.form_code
         , x.model
         , x.fields
         , x.line_items
         , x.prompt_tokens
         , x.completion_tokens
         , x.seconds
      from adm_my_form_extractions_v x
     where x.profile_name = 'pfx_supplier_forms'
       and x.document_name = '&pfx_document'
  ) loop
    sys.dbms_output.put_line(x.status || ', form ' || x.form_code || ', ' || x.model || ', '
      || x.prompt_tokens || ' prompt tokens, ' || x.completion_tokens || ' completion tokens, '
      || to_char(x.seconds, 'fm990D0', 'nls_numeric_characters=''.,''') || ' s');
    sys.dbms_output.put_line(json_query(x.fields, '$' returning clob pretty));
    l_lines := json_array_t(x.line_items);
    <<line_loop>>
    for i in 0 .. l_lines.get_size - 1 loop
      sys.dbms_output.put_line('line ' || (i + 1) || ': ' || l_lines.get(i).to_string);
    end loop line_loop;
  end loop result_loop;
end;
/

-- ---------------------------------------------------------------------------
-- Read the annotations in ADM
-- ---------------------------------------------------------------------------
column annotation_key format a28
column annotation_value format a20
select a.annotation_key
     , a.annotation_value
  from adm_my_document_annotations_v a
  join adm_my_documents_v d
    on d.document_id = a.document_id
 where d.folder_path = '&pfx_home/pfx_samples'
   and d.document_name = '&pfx_document'
   and a.annotation_key not like 'file.%'
 order by a.annotation_key;

undefine pfx_document
