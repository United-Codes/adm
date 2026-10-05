create or replace package body hkd_ai_backfill_api as

  pragma serially_reusable;


  function queued_events return number
  as
    l_count number;
  begin
    select count(*)
      into l_count
      from aq$hkd_event_qt
     where queue     = 'HKD_EVENT_Q'
       and msg_state in ('READY', 'WAIT');
    return l_count;
  end queued_events;


  procedure estimate (
    p_folder_path         in  varchar2 default null
  , po_documents          out number
  , po_prompt_tokens      out number
  , po_completion_tokens  out number
  )
  as
    l_avg_prompt     number;
    l_avg_completion number;
  begin
    select count(*)
      into po_documents
      from hkd_ai_candidates_v c
     where (p_folder_path is null
            or c.folder_path = lower(p_folder_path)
            or c.folder_path like adm_utils.escape_like(lower(p_folder_path)) || '/%' escape '\')
       and not exists (
             select 1
               from hkd_ai_results r
              where r.document_id = c.document_id
           );

    -- The mean of every verdict so far, reruns included. It is 0 before the first verdict.
    select avg(prompt_tokens)
         , avg(completion_tokens)
      into l_avg_prompt
         , l_avg_completion
      from hkd_ai_results
     where status != 'FAILED';

    po_prompt_tokens     := round(po_documents * coalesce(l_avg_prompt, 0));
    po_completion_tokens := round(po_documents * coalesce(l_avg_completion, 0));
  end estimate;


  function enqueue_unclassified (
    p_batch_size  in number default 20
  , p_folder_path in varchar2 default null
  , p_max_queued  in number default 40
  ) return number
  as
    l_count number := 0;
  begin
    if queued_events >= p_max_queued then
      return 0;
    end if;

    <<document_loop>>
    for r in (
      select c.document_id
           , c.latest_version_id
        from hkd_ai_candidates_v c
       where (p_folder_path is null
              or c.folder_path = lower(p_folder_path)
              or c.folder_path like adm_utils.escape_like(lower(p_folder_path)) || '/%' escape '\')
         and not exists (
               select 1
                 from hkd_ai_results x
                where x.document_id = c.document_id
             )
       order by c.created_date
       fetch first p_batch_size rows only
    ) loop
      hkd_hook_api.enqueue_event('AI_RECLASSIFY', p_document_id => r.document_id, p_version_id => r.latest_version_id);
      l_count := l_count + 1;
    end loop document_loop;

    return l_count;
  end enqueue_unclassified;


  function enqueue_outdated (
    p_before      in timestamp with local time zone
  , p_folder_path in varchar2 default null
  , p_batch_size  in number default 20
  , p_max_queued  in number default 40
  ) return number
  as
    l_count number := 0;
  begin
    if queued_events >= p_max_queued then
      return 0;
    end if;

    <<document_loop>>
    for r in (
      select c.document_id
           , c.latest_version_id
        from hkd_ai_candidates_v c
        join hkd_ai_latest_v v
          on v.document_id = c.document_id
       where v.created_at < p_before
         and v.status != 'FAILED'
         and not (v.status in ('ACCEPTED', 'REVOKED') and v.version_id = c.latest_version_id)
         and (p_folder_path is null
              or c.folder_path = lower(p_folder_path)
              or c.folder_path like adm_utils.escape_like(lower(p_folder_path)) || '/%' escape '\')
       order by v.created_at
       fetch first p_batch_size rows only
    ) loop
      hkd_hook_api.enqueue_event('AI_RECLASSIFY', p_document_id => r.document_id, p_version_id => r.latest_version_id);
      l_count := l_count + 1;
    end loop document_loop;

    return l_count;
  end enqueue_outdated;

end hkd_ai_backfill_api;
/
