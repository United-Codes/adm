-- Lesson 3: runs the markers of every form of the profile against the text of every sample PDF
-- and prints the forms that match. A document must match exactly one form, or none when it is no
-- form. Calls no model. Run in SQLcl or SQL*Plus, connected as the ADM schema owner.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

@@settings.sql

set define on
set verify off
set feedback off
set serveroutput on

declare
  l_profile_id number;
  l_forms      apex_t_varchar2;
begin
  adm_context_api.system_user_login('&pfx_user');
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');
  <<document_loop>>
  for d in (
    select document_id
         , document_name
      from adm_my_documents_v
     where folder_path = '&pfx_home/pfx_samples'
       and file_mime_type = 'application/pdf'
     order by document_name
  ) loop
    l_forms := adm_ai_form_extract_api.matching_forms(
                 p_profile_id => l_profile_id
               , p_text       => adm_ai_form_extract_api.document_text(d.document_id)
               );
    sys.dbms_output.put_line(
      rpad(d.document_name, 44)
      || case l_forms.count
           when 0 then '-'
           when 1 then l_forms(1)
           else 'MORE THAN ONE: ' || apex_string.join(l_forms, ', ')
         end
    );
  end loop document_loop;
end;
/
