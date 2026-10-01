---
name: adm-sharing-and-permissions
description: >
  Permissions and sharing in APEX Document Management (ADM) from PL/SQL - checking whether a
  user may view or change something (adm_access_control_api), sharing documents and folders with
  users and groups (adm_shares_api), public link shares with a password and expiry
  (adm_link_shares_api), embed tokens (adm_embed_api), and creating users and groups
  (adm_user_api, adm_group_api). Use whenever a task involves ADM permissions, "who may see
  this", sharing, a share URL, an embed token, or provisioning ADM users, roles and groups.
  Read the adm-plsql skill first.
---

# Permissions and sharing

Needs an established context and your own `commit` — see `adm-plsql`.

## How access is decided

Five things can grant access to a document or folder, and ADM considers all of them:

1. **The user's role** — `ADMIN`, `EDIT` or `VIEW` in the session context, from their ADM role
   (`ADMIN` / `CONTRIBUTOR` / `VIEWER` in `adm_roles`). `ADMIN` bypasses the checks.
2. **Ownership** — their own home folder `/users/<name>` and everything below it.
3. **Group ownership** — a group folder, reachable by every member of that group.
4. **A share** — on the document itself, or on any folder above it. Folder shares are inherited
   downwards.
5. **A bearer token** — a public link share URL, or an embed token, both of which grant access
   without an ADM login.

Do not try to reproduce that with joins. Ask.

## Asking

```sql
if adm_access_control_api.user_is_allowed_to_view_document(p_document_id => 4711) then ...
if adm_access_control_api.user_has_edit_rights_on_document(p_document_id => 4711)
     = adm_access_control_api.c_edit then ...
if adm_access_control_api.user_has_owner_rights_on_document(p_document_id => 4711) then ...

if adm_access_control_api.is_allowed_to_view_folder(p_folder_id => 99) then ...
if adm_access_control_api.user_has_edit_rights_on_folder(p_folder_id => 99)
     = adm_access_control_api.c_edit then ...
if adm_access_control_api.user_has_owner_rights_on_folder(p_folder_id => 99) then ...
```

- **Every one of them defaults `p_username` to the context user**, so an ordinary call passes only
  an id. Pass `p_username` explicitly only when asking about somebody else.
- The `user_has_edit_rights_*` functions return **`varchar2`** — compare against
  `adm_access_control_api.c_edit` (`'EDIT'`), never to `true`.
- `user_is_allowed_to_view_document` and `is_allowed_to_view_folder` return **`boolean`**, so they
  are PL/SQL-only before Oracle 23ai. For SQL, use
  `adm_access_control_api.is_allowed_to_view_folder_yn(...) = 'Y'`.
- Guarding an administrative operation of your own:
  ```sql
  adm_access_control_api.assert_admin(p_operation => 'rebuild the case index');
  ```
  raises `adm_error.e_admin_required` unless the context holds `ADMIN`. `user_is_admin` is the
  predicate form.

**Call the check even when you are about to call an ADM API that checks anyway.** The API refuses
with an error; your code usually wants to skip the row, or show a different message, or count what
was inaccessible. The one thing never to do is decide access yourself.

Note that under `adm_context_api.system_login` every check passes — that is the point of it. Use
`system_user_login` when the answer should reflect a real person's rights.

## Sharing with users and groups

```sql
adm_shares_api.share_document(
  p_document_id => 4711
, p_user_ids    => '1001:1002'    -- colon-separated USER IDs, null for none
, p_groups_ids  => '55'           -- colon-separated GROUP IDs, null for none
, p_share_role  => adm_access_control_api.c_edit    -- or c_view
);

adm_shares_api.share_folder(
  p_folder_id   => 99
, p_user_ids    => '1001'
, p_groups_ids  => null
, p_share_role  => adm_access_control_api.c_view
);
```

The lists are **ids, not usernames**, colon-separated — the format APEX shuttles produce. Resolve
names first:

```sql
select listagg(u.user_id, ':')
  into l_user_ids
  from adm_users u
 where u.username in ('JDOE', 'ASMITH')
   and u.is_active = 'Y';
```

Sharing a folder grants access to everything below it. Removing a share needs the share's own id,
from `adm_document_shares` / `adm_folder_shares` (or the `adm_report_*_shares_v` views):

```sql
adm_shares_api.delete_share_document(p_doc_share_id => l_doc_share_id);
adm_shares_api.delete_share_folder(p_folder_share_id => l_folder_share_id);
```

There is no "share with everyone": use a group. Trashing or deleting an asset revokes its shares
automatically.

## Public link shares

A link share is a **bearer token**: whoever holds the URL has the access. The only guards are the
optional expiry and the optional password, which is why an expiry should be treated as mandatory in
your own code.

```sql
adm_link_shares_api.create_document_link_share(
  p_document_id     => 4711
, p_expiration_date => systimestamp + 14
, p_share_role      => adm_access_control_api.c_view    -- c_edit lets an anonymous holder upload a new version
, p_password        => 'correct horse'                  -- null publishes an unprotected link
);
```

Creating one takes **EDIT rights on the document** — the same as any other kind of sharing.

It is a procedure with no OUT parameter, so read the token back from the table and build the URL:

```sql
select adm_link_shares_api.get_share_url(p_share_url_token => s.share_url_token)
  into l_url
  from adm_document_link_shares s
 where s.doc_link_share_id = (
         select max(doc_link_share_id) from adm_document_link_shares where document_id = 4711
       );
```

`get_share_url` returns an absolute, session-less URL, so it survives being mailed and bookmarked.
The password is stored only as a hash and **cannot be changed** — delete the row and publish a new
link. To change expiry or role while keeping the URL working:

```sql
adm_link_shares_api.modify_document_link_share(
  p_doc_link_share_id => l_id
, p_expiration_date   => systimestamp + 30
, p_share_role        => adm_access_control_api.c_view
);
```

There is no delete procedure: remove the `adm_document_link_shares` row.

If you build your own share landing page, redeem the token through the API — it validates,
resolves the document, audits the use, and delays before raising so the endpoint cannot be used to
guess tokens:

```sql
adm_link_shares_api.check_credentials(
  p_share_url_token    => :P1_TOKEN
, p_password           => :P1_PASSWORD
, po_document_id       => l_document_id
, po_doc_link_share_id => l_share_id
);
-- raises adm_error.e_invalid_credentials (unknown token or wrong password - deliberately
-- indistinguishable) or adm_error.e_expired
```

Every link-share operation is audited, including each redemption (`USE_SHARE_LINK`).

## Embed tokens

An embed token lets another application render an ADM document or folder without an ADM login. It
bounds what the embedded window can reach — see the Embedding guide for the page setup:
<https://united-codes.com/products/apex-document-management/docs/dev/embedding/>

```sql
l_token := adm_embed_api.get_or_create_document_token(
  p_document_id => 4711
, p_description => 'Case 2026-0042 viewer'
, p_expires_at  => systimestamp + 1      -- default is 1 day
, p_is_readonly => 'Y'
);

l_token := adm_embed_api.get_or_create_folder_token(p_folder_id => 99);

l_params := adm_embed_api.get_item_values(
  p_embed_token => l_token
, p_username    => sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_username)
);
```

- Minting takes **EDIT** on the asset; a token granting `DELETE` takes **OWNER**.
- `get_or_create_*` reuses an existing token only when its **grant set** matches what you asked for,
  and mints a new one when the old one expires within the hour.
- `get_item_values` checksum-signs the username. You may name your own context user, anyone at all
  if you are an administrator, or — for a token whose permissions carry `"identity": "HOST"` — a
  user of the host application with no `adm_users` row at all.
- Embed tokens are keyed on the asset **path**. Renaming or moving the asset drops them, on purpose.

## Users and groups

```sql
declare
  l_role_id  adm_roles.role_id%type;
  l_group_id adm_groups.group_id%type;
begin
  adm_context_api.system_login;

  select role_id into l_role_id from adm_roles where role_name = 'CONTRIBUTOR';
  adm_user_api.add_user(p_username => 'JDOE', p_role_id => l_role_id);

  adm_group_api.create_group(
    p_group_name  => 'Finance'
  , p_description => 'Finance department'
  , po_group_id   => l_group_id
  );
  adm_group_api.add_user_to_group(
    p_group_id => l_group_id
  , p_user_id  => (select user_id from adm_users where username = 'JDOE')
  );

  commit;
end;
/
```

- Role names in `adm_roles` are `ADMIN`, `CONTRIBUTOR` and `VIEWER`; the context maps the latter two
  to `EDIT` and `VIEW`. Look the id up by name rather than hardcoding a number.
- `add_user` provisions the user's home folder and trash as well. ADM does not authenticate — your
  APEX authentication scheme does — so the username here must match what your app signs in as.
- `adm_user_api.deactivate_user` sets the user inactive **and deletes all their shares** (link
  shares on documents they own, and document and folder shares both to and from them).
  `activate_user` does not bring those back. Deactivating is not reversible in that sense — for a
  temporary block, keep the user active and remove the specific access instead.
- `adm_group_api.remove_user_from_group(p_group_id, p_user_id)` for membership removal.
