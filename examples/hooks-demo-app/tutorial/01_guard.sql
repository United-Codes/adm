-- Lesson 1: refuse an upload from a hook. Run in SQLcl or SQL*Plus, connected as the ADM schema owner,
-- after 00_setup.sql.
--
--   @01_guard.sql
--
-- What it does:
--   1. creates the package hkd_hook_api with the guard (create or replace, so a re-run is safe)
--   2. registers it as the AFTER_NEW_FILE_UPLOAD hook. ADM allows ONE snippet for each event, so this
--      takes the slot. The script refuses to overwrite a snippet that is not this tutorial's.

set verify off
set serveroutput on
whenever sqlerror exit failure

create or replace package hkd_hook_api as

  procedure after_new_file_upload (
    p_document_id in adm_documents.document_id%type
  , p_version_id  in adm_document_versions.version_id%type
  );

end hkd_hook_api;
/

create or replace package body hkd_hook_api as

  -- Errors raised by customer code use -20700 .. -20999. ADM never uses that range, and it does not
  -- wrap an error from it: the user reads the message, so write it for the user.
  c_err_blocked_extension constant number := -20701;
  c_err_empty_file        constant number := -20702;


  -- Keeps a record of a refusal. The user reads the reason in the error, but a refused upload leaves
  -- nothing behind in ADM, so this table is how an administrator sees what was refused. AUTONOMOUS:
  -- the hook refuses by raising, the raise rolls the upload back, and an ordinary insert would be
  -- rolled back with it. The pragma commits this one row and leaves the caller's transaction alone.
  procedure log_rejection (
    p_hook_key in varchar2
  , p_subject  in varchar2
  , p_reason   in varchar2
  )
  as
    pragma autonomous_transaction;
  begin
    insert into hkd_rejections (hook_key, subject, reason, rejected_by)
    values (p_hook_key, substr(p_subject, 1, 1000), substr(p_reason, 1, 1000), sys_context('ADM_CONTEXT', 'ADM_USERNAME'));

    commit;
  end log_rejection;


  -- Refuses the file when a rule says so, with a message for the user. Reads metadata only, never the
  -- file content.
  procedure guard_file (
    p_hook_key    in varchar2
  , p_document_id in adm_documents.document_id%type
  , p_version_id  in adm_document_versions.version_id%type
  )
  as
    l_name      adm_documents.document_name%type;
    l_file_size adm_document_versions.file_size%type;
    l_extension varchar2(20 char);
    l_reason    hkd_blocked_extensions.reason%type;
    l_message   varchar2(1000 char);
  begin
    select d.document_name
         , v.file_size
      into l_name
         , l_file_size
      from adm_documents d
      join adm_document_versions v
        on v.document_id = d.document_id
     where d.document_id = p_document_id
       and v.version_id  = p_version_id;

    if instr(l_name, '.') > 0 then
      l_extension := lower(regexp_substr(l_name, '[^.]+$'));

      begin
        select reason
          into l_reason
          from hkd_blocked_extensions
         where extension = l_extension;

        l_message := 'Files of type .' || l_extension || ' are not accepted: ' || l_reason;
        log_rejection(p_hook_key, l_name, l_message);
        raise_application_error(c_err_blocked_extension, l_message);
      exception
        when no_data_found then
          null;
      end;
    end if;

    if nvl(l_file_size, 0) = 0 then
      l_message := 'The file is empty (0 bytes), there is nothing to store';
      log_rejection(p_hook_key, l_name, l_message);
      raise_application_error(c_err_empty_file, l_message);
    end if;
  end guard_file;


  procedure after_new_file_upload (
    p_document_id in adm_documents.document_id%type
  , p_version_id  in adm_document_versions.version_id%type
  )
  as
  begin
    guard_file(adm_hooks_api.c_after_new_file_upload, p_document_id, p_version_id);
  end after_new_file_upload;

end hkd_hook_api;
/

show errors

-- Register the hook: ADM runs this text as PL/SQL, with the event's parameters bound by name.
declare
  l_current adm_hooks.hook_plsql%type;
begin
  select hook_plsql
    into l_current
    from adm_hooks
   where hook_key = 'AFTER_NEW_FILE_UPLOAD';

  if l_current is not null and l_current not like 'hkd_hook_api.%' then
    raise_application_error(-20700, 'AFTER_NEW_FILE_UPLOAD already runs other code. Not overwriting it:' || chr(10) || l_current);
  end if;

  update adm_hooks
     set hook_plsql   = 'hkd_hook_api.after_new_file_upload(p_document_id => :p_document_id, p_version_id => :p_version_id);'
       , updated_by   = 'HKD_TUTORIAL'
       , updated_date = current_timestamp
   where hook_key = 'AFTER_NEW_FILE_UPLOAD';

  commit;
end;
/

set feedback off
prompt
prompt Registered hooks:
begin
  for r in (select hook_key, hook_plsql from adm_hooks where hook_plsql is not null order by hook_key) loop
    dbms_output.put_line(r.hook_key || ':');
    dbms_output.put_line('  ' || r.hook_plsql);
  end loop;
end;
/

whenever sqlerror continue
