-- Lesson 5: how many documents of each form needed a person, by week. A rise for one form often
-- means that its issuer changed the layout. Calls no model.

@@settings.sql

set define on
set verify off
set feedback off
set linesize 200

begin
  adm_context_api.system_user_login('&pfx_user');
end;
/

column form format a24
column week format a10
select nvl(x.form_code, '(no form)') as form
     , to_char(trunc(x.extracted_at, 'IW'), 'YYYY-MM-DD') as week
     , count(*) as documents
     , count(case when x.status != 'OK' then 1 end) as needed_a_person
     , round(100 * count(case when x.status != 'OK' then 1 end) / count(*)) as percent
  from adm_my_form_extractions_v x
 where x.profile_name = 'pfx_supplier_forms'
 group by nvl(x.form_code, '(no form)') -- @dblinter ignore(g-3183): 19c cannot group by a column alias
        , trunc(x.extracted_at, 'IW')
 order by week, form;
