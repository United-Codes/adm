-- Lesson 4: measures the whole test set once for each candidate model, and prints one line for
-- each model. Change the list to the models on your Ollama server, and pull every model first.
-- Each model must read text and images. The script calls each model once for each PDF and twice
-- for each image, so it takes several minutes. It writes only the rows of adm_ai_form_measurements.

@@settings.sql

set define on
set verify off
set feedback off
set linesize 200

-- ---------------------------------------------------------------------------
-- Measure the candidate models
-- ---------------------------------------------------------------------------
declare
  l_profile_id number;
begin
  adm_context_api.system_user_login('&pfx_user');
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');
  <<model_loop>>
  for m in (select column_value as model from table(apex_t_varchar2('qwen3.5:9b', 'gemma4:26b'))) loop
    -- p_model replaces the model of text_model, p_vision_model the model of vision_model.
    -- Everything else of the profile stays the same.
    adm_ai_form_extract_api.measure(
      p_profile_id => l_profile_id
    , p_label      => 'text ' || m.model
    , p_name_like  => '%.pdf'
    , p_model      => m.model
    );
    adm_ai_form_extract_api.measure(
      p_profile_id   => l_profile_id
    , p_label        => 'image ' || m.model
    , p_name_like    => '%.png'
    , p_vision_model => m.model
    );
    commit; -- @dblinter ignore(g-3310): keeps the runs of the models that finished
  end loop model_loop;
end;
/

-- ---------------------------------------------------------------------------
-- Compare the models
-- ---------------------------------------------------------------------------
column label format a18
column median_s format a8
column max_s format a7
column not_right format a70 word_wrapped

with latest as (
  select m.label
       , m.document_name
       , m.outcome
       , m.seconds
       , row_number() over (partition by m.label, m.document_id order by m.measurement_id desc) as rn
    from adm_ai_form_measurements m
   where m.profile_id = (select p.profile_id from adm_ai_form_profiles p where p.profile_name = 'pfx_supplier_forms')
     and (m.label like 'text %' or m.label like 'image %')
)
select label
     , count(*) as documents
     , count(case when outcome = 'RIGHT' then 1 end) as right
     , count(case when outcome = 'CAUGHT' then 1 end) as caught
     , count(case when outcome = 'MISSED' then 1 end) as missed
     , count(case when outcome = 'FAILED' then 1 end) as failed
     , to_char(median(nullif(seconds, 0)), '990.0') as median_s
     , to_char(max(seconds), '990.0') as max_s
     , listagg(case when outcome != 'RIGHT' then document_name || ' (' || outcome || ')' end, ', ')
         within group (order by document_name) as not_right
  from latest
 where rn = 1
 group by label
 order by label;
