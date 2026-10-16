-- Lesson 5: creates the table pfx_invoices of "your" application, the package pfx_hook_api, and
-- registers pfx_hook_api.after_form_extraction as the AFTER_FORM_EXTRACTION hook of ADM. From then
-- on, every accepted invoice of the profile pfx_supplier_forms (status OK or APPROVED) is copied
-- into pfx_invoices, in the same transaction as the extraction.
--
-- ADM keeps one hook snippet for each event. When AFTER_FORM_EXTRACTION already runs other code,
-- the script stops and changes nothing. 99_uninstall.sql frees the hook again.
-- Run in SQLcl or SQL*Plus, connected as the ADM schema owner. Calls no model. Running it again
-- creates the table again, empty.

set define off
set feedback off
set serveroutput on

declare
  c_drop constant varchar2(40 char) := 'drop table pfx_invoices purge';
  -- ORA-00942: the table does not exist yet.
  e_table_missing exception;
  pragma exception_init(e_table_missing, -942);
begin
  execute immediate c_drop;
exception
  when e_table_missing then
    null;
end;
/

-- ---------------------------------------------------------------------------
-- The table of your application
-- ---------------------------------------------------------------------------
create table pfx_invoices (
  document_id     number not null,
  invoice_number  varchar2(100 char) not null,
  invoice_date    date,
  customer_number varchar2(100 char),
  customer_name   varchar2(400 char),
  total_amount    number,
  line_count      number,
  source_status   varchar2(10 char) not null,
  imported_at     timestamp with local time zone default on null current_timestamp not null,
  constraint pfx_invoices_pk primary key (document_id),
  -- a deleted document takes its row with it
  constraint pfx_invoices_document_fk foreign key (document_id)
      references adm_documents (document_id) on delete cascade
);

comment on table pfx_invoices is 'Course "Extract data from PDF forms": the accepted invoices, copied by the AFTER_FORM_EXTRACTION hook.';
comment on column pfx_invoices.document_id is 'The ADM document of the invoice.';
comment on column pfx_invoices.invoice_number is 'Invoice number as extracted or approved.';
comment on column pfx_invoices.invoice_date is 'Invoice date.';
comment on column pfx_invoices.customer_number is 'Customer number at the issuer.';
comment on column pfx_invoices.customer_name is 'Customer name.';
comment on column pfx_invoices.total_amount is 'Total amount of the invoice.';
comment on column pfx_invoices.line_count is 'Number of line items.';
comment on column pfx_invoices.source_status is 'OK: every check passed. APPROVED: a person approved the values.';
comment on column pfx_invoices.imported_at is 'When the hook wrote the row.';

-- ---------------------------------------------------------------------------
-- The hook procedure
-- ---------------------------------------------------------------------------
create or replace package pfx_hook_api
  authid definer
as
  /**
   * AFTER_FORM_EXTRACTION hook of the course "Extract data from PDF forms": copies an accepted
   * invoice of the profile pfx_supplier_forms into pfx_invoices. Runs in the transaction of the
   * extraction or the approval; it never commits.
   */
  procedure after_form_extraction (
    p_document_id   in number
  , p_version_id    in number
  , p_profile_id    in number
  , p_extraction_id in number
  , p_status        in varchar2
  );
end pfx_hook_api;
/

create or replace package body pfx_hook_api
as
  procedure after_form_extraction (
    p_document_id   in number   -- @dblinter ignore(g-7150): ADM binds every parameter of the event
  , p_version_id    in number   -- @dblinter ignore(g-7150): ADM binds every parameter of the event
  , p_profile_id    in number   -- @dblinter ignore(g-7150): the profile name in the view selects the course profile
  , p_extraction_id in number
  , p_status        in varchar2
  )
  as
  begin
    -- The hook runs for every profile: take only the invoices of this course.
    <<extraction_loop>>
    for x in (
      select x.document_id
           , x.fields
           , x.line_items
        from adm_my_form_extractions_v x
       where x.extraction_id = p_extraction_id
         and x.profile_name  = 'pfx_supplier_forms'
         and x.doc_type      = 'invoice'
    ) loop
      merge into pfx_invoices i
      using (
        select x.document_id as document_id
             , json_value(x.fields, '$.invoice_number') as invoice_number
             , to_date(json_value(x.fields, '$.invoice_date') default null on conversion error, 'YYYY-MM-DD') as invoice_date
             , json_value(x.fields, '$.customer_number') as customer_number
             , json_value(x.fields, '$.customer_name') as customer_name
             , json_value(x.fields, '$.total_amount' returning number) as total_amount
             , json_value(x.line_items, '$.size()') as line_count
          from dual
      ) s
         on (i.document_id = s.document_id)
       when matched then update set
            i.invoice_number  = s.invoice_number
          , i.invoice_date    = s.invoice_date
          , i.customer_number = s.customer_number
          , i.customer_name   = s.customer_name
          , i.total_amount    = s.total_amount
          , i.line_count      = s.line_count
          , i.source_status   = p_status
          , i.imported_at     = current_timestamp
       when not matched then insert (
            document_id, invoice_number, invoice_date, customer_number, customer_name, total_amount, line_count, source_status)
       values (
            s.document_id, s.invoice_number, s.invoice_date, s.customer_number, s.customer_name, s.total_amount, s.line_count, p_status);
    end loop extraction_loop;
  end after_form_extraction;
end pfx_hook_api;
/

-- ---------------------------------------------------------------------------
-- Register the hook
-- ---------------------------------------------------------------------------
declare
  l_current adm_hooks.hook_plsql%type;
begin
  select hook_plsql
    into l_current
    from adm_hooks
   where hook_key = 'AFTER_FORM_EXTRACTION';

  if l_current is not null and l_current not like 'pfx_hook_api.%' then
    raise_application_error(-20700, 'AFTER_FORM_EXTRACTION already runs other code. Not overwriting it: ' || l_current);
  end if;

  update adm_hooks
     set hook_plsql   = 'pfx_hook_api.after_form_extraction(p_document_id => :p_document_id, p_version_id => :p_version_id, '
                        || 'p_profile_id => :p_profile_id, p_extraction_id => :p_extraction_id, p_status => :p_status);'
       , updated_by   = 'PFX_COURSE'
       , updated_date = current_timestamp
   where hook_key = 'AFTER_FORM_EXTRACTION';
  commit;
  sys.dbms_output.put_line('hook AFTER_FORM_EXTRACTION: pfx_hook_api.after_form_extraction'); -- @dblinter ignore(g-5010): a tutorial script prints its result for the reader
end;
/
