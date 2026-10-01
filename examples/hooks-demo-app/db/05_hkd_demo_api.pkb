create or replace package body hkd_demo_api as

  c_scope_prefix constant varchar2(30 char) := 'hkd_demo_api.';

  c_err_bad_input constant number := -20711;


  procedure establish_context
  as
    l_role adm_roles.role_name%type;
  begin
    select r.role_name
      into l_role
      from adm_users u
      join adm_roles r
        on r.role_id = u.role_id
     where u.username  = upper(v('APP_USER'))
       and u.is_active = 'Y';

    adm_context_api.apex_login(
      p_username => upper(v('APP_USER'))
    , p_role     => l_role
    );
  exception
    when no_data_found then
      -- an APEX account without an ADM account: no identity, so no data. The app's
      -- authorization scheme tells the user why.
      adm_context_api.clear_context;
  end establish_context;


  procedure upload_file (
    p_folder_id    in  number
  , p_temp_file    in  varchar2
  , po_document_id out number
  , po_result      out varchar2
  , po_file_name   out varchar2
  )
  as
    l_mime_type   apex_application_temp_files.mime_type%type;
    l_content     blob;
    l_before      adm_documents.latest_version_id%type;
    l_after       adm_document_versions.version_id%type;
  begin
    select filename
         , mime_type
         , blob_content
      into po_file_name
         , l_mime_type
         , l_content
      from apex_application_temp_files
     where name = p_temp_file;

    -- keep just the file name, a browser may send a client path
    po_file_name := regexp_substr(po_file_name, '[^/\\]+$');

    begin
      select document_id
           , latest_version_id
        into po_document_id
           , l_before
        from adm_documents
       where folder_id     = p_folder_id
         and document_name = po_file_name
         and deleted_flag  = 'N';

      l_after := adm_document_api.add_document_version(
                   p_document_id  => po_document_id
                 , p_file_content => l_content
                 , p_allow_merge  => false
                 );
      po_result := case when l_after = l_before then 'UNCHANGED' else 'NEW_VERSION' end;
    exception
      when no_data_found then
        po_document_id := adm_document_api.create_document(
                            p_folder_id      => p_folder_id
                          , p_document_name  => po_file_name
                          , p_file_content   => l_content
                          , p_file_mime_type => coalesce(l_mime_type, 'application/octet-stream')
                          );
        po_result := 'CREATED';
    end;
  end upload_file;


  function create_folder (
    p_parent_folder_id in number
  , p_folder_name      in varchar2
  ) return number
  as
  begin
    return adm_folder_api.add_folder(
             p_folder_name      => trim(p_folder_name)
           , p_parent_folder_id => p_parent_folder_id
           );
  end create_folder;


  procedure set_workflow_enabled (
    p_workflow_code in varchar2
  , p_enabled       in varchar2
  )
  as
  begin
    update hkd_workflows
       set enabled_flag = case when p_enabled = 'Y' then 'Y' else 'N' end
     where workflow_code = p_workflow_code;
  end set_workflow_enabled;


  procedure add_blocked_extension (
    p_extension in varchar2
  , p_reason    in varchar2 default null
  )
  as
    l_extension hkd_blocked_extensions.extension%type := lower(ltrim(trim(p_extension), '.'));
  begin
    if l_extension is null or not regexp_like(l_extension, '^[a-z0-9]{1,20}$') then
      raise_application_error(c_err_bad_input, 'An extension is letters and digits only, for example: exe');
    end if;

    merge into hkd_blocked_extensions t
    using (select l_extension as extension from dual) s
       on (t.extension = s.extension)
     when not matched then
       insert (extension, reason)
       values (s.extension, nvl(p_reason, 'Blocked by the demo'));
  end add_blocked_extension;


  procedure remove_blocked_extension (
    p_extension in varchar2
  )
  as
  begin
    delete from hkd_blocked_extensions
     where extension = lower(p_extension);
  end remove_blocked_extension;


  procedure process_now
  as
  begin
    hkd_worker_api.process_queue;
  end process_now;


  function html_pre (
    p_code in clob
  ) return clob
  as
  begin
    return '<pre style="overflow:auto;margin:.5rem 0 0;padding:1rem;border:1px solid var(--a-region-border-color,#d4d4d4);'
        || 'border-radius:6px;background:rgba(127,127,127,.08);font-size:.85em;line-height:1.45"><code>'
        || apex_escape.html(p_code)
        || '</code></pre>';
  end html_pre;


  function render_source (
    p_package in varchar2
  , p_unit    in varchar2
  , p_intro   in varchar2 default null
  ) return clob
  as
    type t_lines is table of varchar2(4000 char) index by pls_integer;
    l_lines  t_lines;
    l_first  pls_integer;
    l_last   pls_integer;
    l_code   clob;
    l_html   clob;
  begin
    select text
      bulk collect into l_lines
      from user_source
     where name = upper(p_package)
       and type = 'PACKAGE BODY'
     order by line;

    -- the unit starts at the first "  procedure|function <unit>" and ends at "  end <unit>;"
    <<find_start>>
    for i in 1 .. l_lines.count loop
      if regexp_like(l_lines(i), '^  (procedure|function) ' || p_unit || '([ (]|$)', 'i') then
        l_first := i;
        exit find_start;
      end if;
    end loop find_start;

    if l_first is null then
      return '<p><em>Source of ' || apex_escape.html(p_package || '.' || p_unit) || ' not found.</em></p>';
    end if;

    <<find_end>>
    for i in l_first .. l_lines.count loop
      if regexp_like(l_lines(i), '^  end ' || p_unit || ';', 'i') then
        l_last := i;
        exit find_end;
      end if;
    end loop find_end;

    -- take the comment block directly above the unit with it
    while l_first > 1 and regexp_like(l_lines(l_first - 1), '^ {2,3}(--|/\*\*| \*|\*/)') loop
      l_first := l_first - 1;
    end loop;

    dbms_lob.createtemporary(l_code, true);
    for i in l_first .. nvl(l_last, l_lines.count) loop
      -- two spaces of package indentation are noise on a page
      dbms_lob.writeappend(
        l_code
      , length(regexp_replace(l_lines(i), '^  ', '') || case when substr(l_lines(i), -1) = chr(10) then '' else chr(10) end)
      , regexp_replace(l_lines(i), '^  ', '') || case when substr(l_lines(i), -1) = chr(10) then '' else chr(10) end
      );
    end loop;

    l_html := case when p_intro is not null then '<div>' || p_intro || '</div>' end;
    return l_html
        || '<div style="margin-top:.25rem;font-size:.8em;opacity:.7">'
        || apex_escape.html(lower(p_package) || '.' || lower(p_unit)) || '</div>'
        || html_pre(l_code);
  end render_source;


  function render_registered_hooks return clob
  as
    l_html clob;
  begin
    for r in (
      select hook_key
           , hook_plsql
        from adm_hooks
       order by hook_key
    ) loop
      l_html := l_html
             || '<div style="margin-top:.75rem;font-weight:600">' || apex_escape.html(r.hook_key) || '</div>'
             || html_pre(coalesce(r.hook_plsql, '-- not registered'));
    end loop;

    return l_html;
  end render_registered_hooks;


  procedure clear_log
  as
  begin
    delete from hkd_workflow_runs;
    delete from hkd_notifications;
    delete from hkd_rejections;
  end clear_log;

end hkd_demo_api;
/
