-- Lessons 2 to 4: measures the extraction of the test set and prints the report.
-- Run in SQLcl or SQL*Plus, connected as the ADM schema owner. Arguments:
--
--   @02_measure.sql <label> <form code or %> <name like> <rules|naive> <reasoning Y|N>
--   @02_measure.sql baseline HARBOUR_INVOICE %.pdf rules N
--
-- It calls the model once for each document (twice for an image), and writes only the rows of
-- adm_ai_form_measurements. A label that you use again adds a new run; the report shows the
-- latest result of each document.

@@settings.sql

set define on
set verify off
set feedback off

begin
  adm_context_api.system_user_login('&pfx_user');
  adm_ai_form_extract_api.measure(
    p_profile_id => adm_ai_form_config_api.get_profile_id('pfx_supplier_forms')
  , p_label      => '&1'
  , p_form_code  => nullif('&2', '%')
  , p_name_like  => '&3'
  , p_prompt     => '&4'
  , p_think      => '&5' = 'Y' -- @dblinter ignore(g-1040): the script argument fills in the left side
  );
  commit;
end;
/

@@02_report.sql "&1"

undefine 1 2 3 4 5
