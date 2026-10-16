-- Removes the course "Extract data from PDF forms with a local model": the AFTER_FORM_EXTRACTION
-- hook when it is the hook of the course, the profile pfx_supplier_forms with its results, test
-- set and measurements, the folders pfx_samples and pfx_inbox with their documents, and the pfx_
-- objects. The documents are deleted permanently, not moved to the trash. The tag
-- extraction-review stays in ADM. Run in SQLcl or SQL*Plus, connected as the ADM schema owner.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

@@settings.sql

set define on
set verify off
set feedback off
set serveroutput on

declare
  l_folder_id adm_folders.folder_id%type;
  l_sql       varchar2(200 char);
begin
  -- First the hook: a hook that calls a dropped package fails every extraction.
  update adm_hooks
     set hook_plsql   = null
       , updated_by   = 'PFX_COURSE'
       , updated_date = current_timestamp
   where hook_key = 'AFTER_FORM_EXTRACTION'
     and hook_plsql like 'pfx_hook_api.%';
  if sql%rowcount > 0 then
    sys.dbms_output.put_line('freed hook AFTER_FORM_EXTRACTION');
  end if;

  adm_context_api.system_user_login('&pfx_user');
  begin
    adm_ai_form_config_api.delete_profile(adm_ai_form_config_api.get_profile_id('pfx_supplier_forms'));
    sys.dbms_output.put_line('deleted profile pfx_supplier_forms');
  exception
    when adm_ai_error.e_form_profile_not_found then
      sys.dbms_output.put_line('profile pfx_supplier_forms was not there');
  end;

  <<folder_loop>>
  for f in (select column_value as folder_name from table(apex_t_varchar2('pfx_samples', 'pfx_inbox'))) loop
    begin
      l_folder_id := adm_folder_api.get_folder_id('&pfx_home/' || f.folder_name);
      adm_folder_api.trash_folder(l_folder_id, '&pfx_user');
      adm_folder_api.permanently_delete_folder(l_folder_id);
      sys.dbms_output.put_line('deleted folder ' || f.folder_name);
    exception
      when adm_error.e_folder_not_found then
        sys.dbms_output.put_line('folder ' || f.folder_name || ' was not there');
    end;
  end loop folder_loop;
  commit;

  <<object_loop>>
  for o in (
    select object_type, object_name
      from user_objects
     where object_name like 'PFX\_%' escape '\'
       and object_type in ('PACKAGE', 'TABLE', 'VIEW')
     order by case object_type when 'VIEW' then 1 when 'PACKAGE' then 2 else 3 end
  ) loop
    l_sql := 'drop ' || o.object_type || ' ' || o.object_name || case when o.object_type = 'TABLE' then ' cascade constraints purge' end;
    execute immediate l_sql;
    sys.dbms_output.put_line('dropped ' || lower(o.object_type) || ' ' || lower(o.object_name));
  end loop object_loop;
end;
/
