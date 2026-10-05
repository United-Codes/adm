-- Registers the three AI workflows and switches off the rule-based classifier they replace.
--
-- All three rows name the same handler, hkd_ai_api.classify_event. They differ in the event
-- they react to: a new upload, a new version, and an explicit hkd_ai_api.reclassify call.
-- sort_order 50 puts them behind the other workflows of an event, so an error in one of those stops
-- the event before the paid model call.
--
-- INTAKE_CLASSIFY guesses a category from the file name and writes the same category tag the
-- AI workflow writes. Two classifiers on one file would fight over that tag, so it is
-- disabled here and 99_hkd_ai_uninstall.sql switches it back on.
-- Re-runnable.

merge into hkd_workflows t
using (
  select 'AI_CLASSIFY_UPLOAD' as workflow_code
       , 'AFTER_NEW_FILE_UPLOAD' as hook_key
       , 50 as sort_order
       , 'AI classification of an upload' as name
       , 'A language model reads a new PDF or image and decides its document type. Valid answers become the category tag and annotations; types that need review wait for a person.' as description
    from dual
  union all
  select 'AI_CLASSIFY_VERSION'
       , 'AFTER_NEW_FILE_VERSION'
       , 60
       , 'AI classification of a new version'
       , 'The same classification for a new version of a file, because a new version can be a different kind of document.'
    from dual
  union all
  select 'AI_RECLASSIFY'
       , 'AI_RECLASSIFY'
       , 10
       , 'AI classification on request'
       , 'Runs the classification for a document after hkd_ai_api.reclassify queued it, for example after a prompt change.'
    from dual
) s
on (t.workflow_code = s.workflow_code)
when matched then
  update set t.hook_key    = s.hook_key
           , t.sort_order  = s.sort_order
           , t.name        = s.name
           , t.description = s.description
           , t.handler     = 'hkd_ai_api.classify_event'
when not matched then
  insert (workflow_code, hook_key, sort_order, name, description, handler)
  values (s.workflow_code, s.hook_key, s.sort_order, s.name, s.description, 'hkd_ai_api.classify_event');

update hkd_workflows
   set enabled_flag = 'N'
 where workflow_code = 'INTAKE_CLASSIFY';

commit;
