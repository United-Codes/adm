-- Lesson 4: prints one line for each model and kind of document, from the runs whose label starts
-- with "model ". The Manager's runs of the lesson have the same labels. Calls no model.
--
--   @04_compare_report.sql

set define on
set verify off
set feedback off
set linesize 250
set pagesize 100
set sqlformat default

column label format a22
column kind format a6
column median_s format a8
column max_s format a7
column not_right format a90 word_wrapped

with latest as (
  select m.label
       , case when m.document_name like '%.png' then 'image' else 'text' end as kind
       , m.document_name
       , m.outcome
       , m.seconds
       , m.prompt_tokens
       , m.completion_tokens
       , row_number() over (partition by m.label, m.document_id order by m.measurement_id desc) as rn
    from adm_ai_form_measurements m
   where m.profile_id = (select p.profile_id from adm_ai_form_profiles p where p.profile_name = 'pfx_supplier_forms')
     and m.label like 'model %'
)
select label
     , kind
     , count(*) as documents
     , count(case when outcome = 'RIGHT' then 1 end) as right
     , count(case when outcome = 'CAUGHT' then 1 end) as caught
     , count(case when outcome = 'MISSED' then 1 end) as missed
     , count(case when outcome = 'FAILED' then 1 end) as failed
     , to_char(median(nullif(seconds, 0)), '990.0') as median_s
     , to_char(max(seconds), '990.0') as max_s
     , sum(prompt_tokens) as prompt_tokens
     , sum(completion_tokens) as completion_tokens
     , listagg(case when outcome != 'RIGHT' then document_name || ' (' || outcome || ')' end, ', ')
         within group (order by document_name) as not_right
  from latest
 where rn = 1
 group by label, kind
 order by label, kind;

set sqlformat ansiconsole
