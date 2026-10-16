-- Prints the report of one measurement run: one line for each document, then the totals. When a
-- label was measured more than once, it takes the latest result of each document. Calls no model.
--
--   @02_report.sql <label>

set define on
set verify off
set feedback off
set linesize 220
set pagesize 100

column document_name format a42
column outcome format a11
column seconds format a7
column details format a100 word_wrapped

with latest as (
  select m.document_name
       , m.outcome
       , m.seconds
       , m.wrong_fields
       , m.issues
       , m.completion_tokens
       , row_number() over (partition by m.document_id order by m.measurement_id desc) as rn
    from adm_ai_form_measurements m
   where m.profile_id = (select p.profile_id from adm_ai_form_profiles p where p.profile_name = 'pfx_supplier_forms')
     and m.label = '&1'
)
select document_name
     , outcome
     , to_char(seconds, '990.0') as seconds
     , case
         when wrong_fields is not null
         then 'wrong: ' || wrong_fields
              || case when issues is not null then ' | issues: ' || replace(issues, chr(10), '; ') end
         when issues is not null
         then 'issues: ' || replace(issues, chr(10), '; ')
       end as details
  from latest
 where rn = 1
 order by document_name;

column documents format 99999
column right format 99999
column false_alarm format 99999
column caught format 99999
column missed format 99999
column failed format 99999
column median_s format a8
column completion_tokens format 9999999

with latest as (
  select m.document_name
       , m.outcome
       , m.seconds
       , m.wrong_fields
       , m.issues
       , m.completion_tokens
       , row_number() over (partition by m.document_id order by m.measurement_id desc) as rn
    from adm_ai_form_measurements m
   where m.profile_id = (select p.profile_id from adm_ai_form_profiles p where p.profile_name = 'pfx_supplier_forms')
     and m.label = '&1'
)
select count(*) as documents
     , count(case when outcome = 'RIGHT' then 1 end) as right
     , count(case when outcome = 'FALSE_ALARM' then 1 end) as false_alarm
     , count(case when outcome = 'CAUGHT' then 1 end) as caught
     , count(case when outcome = 'MISSED' then 1 end) as missed
     , count(case when outcome = 'FAILED' then 1 end) as failed
     , to_char(median(nullif(seconds, 0)), '990.0') as median_s
     , sum(completion_tokens) as completion_tokens
  from latest
 where rn = 1;

undefine 1
