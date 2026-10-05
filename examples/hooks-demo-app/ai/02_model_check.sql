-- Lesson 2: ask several models about the borderline files, three times each. Run in SQLcl or
-- SQL*Plus, connected as the ADM schema owner, after 00_load_pdfs.sql ALL:
--
--   @02_model_check.sql
--
-- It sends 3 files x 3 models x 3 runs = 27 requests to the provider (about 400 tokens each) and
-- prints what each model answered. It writes nothing into ADM and changes no tag.
-- Change the three model names on the define lines to compare others.

define hkd_model_1 = gpt-5.4-nano
define hkd_model_2 = gpt-5.4-mini
define hkd_model_3 = gpt-6.1-sol

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define on
set verify off
set serveroutput on size unlimited
set feedback off

declare
  type t_names is table of varchar2(100 char);
  c_files  constant t_names := t_names('proforma_alpenwerk_pf5531.pdf', 'reminder_ferrotek_1042.pdf', 'delivery_note_nordlicht_ls2207.pdf');
  c_models constant t_names := t_names('&hkd_model_1', '&hkd_model_2', '&hkd_model_3');
  c_runs   constant pls_integer := 3;

  l_version_id adm_documents.latest_version_id%type;
  l_mime       adm_documents.file_mime_type%type;
  l_blob       blob;
  l_messages   json_array_t;
  l_content    json_array_t;
  l_response   json_object_t;
  l_answers    varchar2(200 char);
  l_workspace  apex_workspaces.workspace%type;
begin
  adm_context_api.system_login;
  -- The web credential belongs to a workspace, so the call needs one.
  select min(workspace)
    into l_workspace
    from apex_workspaces
   where workspace != 'INTERNAL';
  apex_util.set_workspace(l_workspace);

  sys.dbms_output.put_line(rpad('file', 38) || rpad('model', 14) || 'answers of ' || c_runs || ' runs');

  <<file_loop>>
  for f in 1 .. c_files.count loop
    select latest_version_id
         , file_mime_type
      into l_version_id
         , l_mime
      from adm_documents
     where document_name = c_files(f)
       and deleted_flag  = 'N'
     fetch first 1 row only;

    l_blob := adm_storage_api.get_file_content(l_version_id, p_from_sql => false);

    <<model_loop>>
    for m in 1 .. c_models.count loop
      l_answers := null;

      <<run_loop>>
      for run in 1 .. c_runs loop
        l_content  := json_array_t();
        l_messages := json_array_t();
        l_content.append(uc_ai_message_api.create_file_content(l_mime, l_blob, c_files(f)));
        l_content.append(uc_ai_message_api.create_text_content('Which type of document is this?'));
        l_messages.append(uc_ai_message_api.create_system_message(hkd_ai_api.get_system_prompt));
        l_messages.append(uc_ai_message_api.create_user_message(l_content));

        l_response := uc_ai.generate_text(
          p_messages             => l_messages
        , p_provider             => hkd_ai_api.c_provider
        , p_model                => c_models(m)
        , p_config               => json_object_t('{"g_apex_web_credential":"' || hkd_ai_api.c_credential || '"}')
        , p_response_json_schema => hkd_ai_api.get_response_schema
        );

        l_answers := l_answers || json_object_t.parse(l_response.get_clob('final_message')).get_string('doc_type') || ' ';
      end loop run_loop;

      sys.dbms_output.put_line(rpad(c_files(f), 38) || rpad(c_models(m), 14) || l_answers);
    end loop model_loop;
  end loop file_loop;
end;
/
