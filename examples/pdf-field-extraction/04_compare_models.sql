-- Lesson 4: measures the whole test set once for each candidate model, and prints one line for
-- each model and kind of document. The models are the list pfx_compare_models in settings.sql,
-- of the provider of the profile. With Ollama, pull every model first.
-- Each model must read text and images. The script calls each model once for each PDF with text
-- and twice for each image, so it takes several minutes. It writes only the rows of
-- adm_ai_form_measurements. A model that you measured before gets a new run with the same label:
-- the report shows the latest result of each document.

@@settings.sql

set define on
set verify off
set feedback off
set linesize 220

-- ---------------------------------------------------------------------------
-- Measure the candidate models
-- ---------------------------------------------------------------------------
declare
  l_profile_id number;
begin
  adm_context_api.system_user_login('&pfx_user');
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');
  <<model_loop>>
  for m in (select trim(column_value) as model from table(apex_string.split('&pfx_compare_models', ','))) loop
    -- p_model replaces the model of text_model, p_vision_model the model of vision_model.
    -- Everything else of the profile stays the same.
    adm_ai_form_extract_api.measure(
      p_profile_id   => l_profile_id
    , p_label        => 'model ' || m.model
    , p_model        => m.model
    , p_vision_model => m.model
    );
    commit; -- @dblinter ignore(g-3310): keeps the runs of the models that finished
  end loop model_loop;
end;
/

@@04_compare_report.sql
