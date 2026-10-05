-- Lesson 2: measure the classifier against the sample labels. Run in SQLcl or SQL*Plus,
-- connected as the ADM schema owner, after the whole sample set is loaded and classified:
--
--   @00_load_pdfs.sql ALL
--   @wait.sql
--   @02_measure.sql
--
-- Reads data only. It makes no model call.

set serveroutput on
set feedback off
set linesize 200
set pagesize 100
column file_name format a36
column expected_type format a9
column classified format a10
column status format a13
column verdict format a24
column tokens_in format 99999 heading 'TOKENS_IN'

-- ---------------------------------------------------------------------------
-- Compare each file with its label
-- ---------------------------------------------------------------------------
select l.file_name
     , l.expected_type
     , r.doc_type as classified
     , r.status
     , case
         when r.doc_type = l.expected_type then 'right'
         when r.status in ('RELEASED', 'ACCEPTED') then 'WRONG and released'
         else 'wrong, held for review'
       end as verdict
     , r.prompt_tokens as tokens_in
  from hkd_ai_labels l
  join hkd_ai_latest_v r
    on r.document_name = l.file_name
 order by case when r.doc_type = l.expected_type then 1 else 0 end
        , l.file_name;

-- ---------------------------------------------------------------------------
-- Count the verdicts
-- ---------------------------------------------------------------------------
select count(*) as files
     , count(case when r.doc_type = l.expected_type then 1 end) as right_type
     , count(case when r.doc_type != l.expected_type and r.status in ('RELEASED', 'ACCEPTED') then 1 end) as wrong_and_released
     , count(case when r.doc_type != l.expected_type and r.status not in ('RELEASED', 'ACCEPTED') then 1 end) as wrong_held
     , sum(r.prompt_tokens) as prompt_tokens
     , sum(r.completion_tokens) as completion_tokens
  from hkd_ai_labels l
  join hkd_ai_latest_v r
    on r.document_name = l.file_name;
