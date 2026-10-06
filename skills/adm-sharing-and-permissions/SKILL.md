---
name: adm-sharing-and-permissions
description: >
  Permission checks and sharing in APEX Document Management (ADM) from PL/SQL: may a user view or
  edit a document or folder (adm_access_control_api), sharing with users and groups
  (adm_shares_api), public link shares with password and expiry (adm_link_shares_api), embed
  tokens (adm_embed_api), creating users and groups (adm_user_api, adm_group_api). Use for "who can
  see this", share a file, read-only access, publish a link, embed a document in another app,
  provision a user or group. Not for listing what a user can see (adm-querying).
metadata:
  version: "26.2"
---

# Permissions and sharing

Needs an established context and your own `commit` - see `adm-plsql`.

## Gotchas

1. **Only ADMIN bypasses; the role does nothing else.** Access comes from ownership (own home or
   group folder), a share on the document or a folder above it, or a token. A `VIEWER` user with an
   EDIT share can write through the API: limit people with the share role. A share never makes an
   owner: `user_has_owner_rights_*` is true only in the user's own or a group folder.
2. **Under an ADMIN context (`system_login` too) every check is TRUE / `EDIT` for any `p_username`.**
   To prove a person's rights, run as an ordinary user (`system_user_login`) and pass `p_username`
   in **upper case**, as stored in `adm_users`: lower case still matches a home folder, never a share.
3. **`user_has_edit_rights_*` returns `'VIEW'` for a user with no access at all.** Compare with
   `adm_access_control_api.c_edit`, never `true`, and also call the view check.
   `is_allowed_to_view_folder` is TRUE for a null folder id; it is PL/SQL only (SQL: `..._yn`).
4. **`share_document` / `share_folder` take id lists, not names:** colon-separated `varchar2`
   (`to_char(id)`, null for none). A subquery cannot be an actual parameter (PLS-00103): select into
   a local first. Both lists null shares with nobody, silently.
5. **Sharing is not an upsert.** The caller needs EDIT on the asset; an existing share raises
   `e_already_exists`. To change a role, `delete_share_document` / `delete_share_folder` (by share id, from
   `adm_report_document_shares_v` / `adm_report_folder_shares_v`; an unknown id does nothing) and share again.
6. **Trashing or deleting an asset revokes its shares, link shares and embed tokens;** rename and
   move drop only its embed tokens. A trashed or archived document grants nothing through a share.
7. **`create_document_link_share` has no OUT parameter:** read the token from
   `adm_document_link_shares`. The role must be `c_view` / `c_edit` (else `e_share_invalid`). The
   password cannot be changed and there is no delete call: delete the row and publish a new link.
8. **`check_credentials` never sleeps.** After `SHARE_LINK_MAX_ATTEMPTS` wrong passwords within
   `SHARE_LINK_LOCKOUT_MINUTES` a link rejects even the right one. Unknown token, wrong or missing
   password and a locked link all raise `e_invalid_credentials`. A null expiry never expires.
9. **Minting an embed token commits on its own,** so it survives your rollback. `get_or_create_*_token`
    reuses a token matching asset, read-only bit and grant set, ignoring `p_expires_at`: it may be older.
10. **User and group calls need an ADMIN context.** Nothing deletes a user or group or changes a role.
    `add_user` on an existing name raises `e_user_exists`, `create_group` on a taken name
    `e_group_exists`. A failed `system_user_login` leaves no identity: log in again.

## Recipes

Replace `4711`, `JDOE` (owner, has EDIT), `ASMITH`, `BWHITE` (member of group `FINANCE`). A recipe without
`declare` is statements for your own block: declare its `l_*` locals with the matching `%type`.

### Share read-only with a user and a group, and prove it

```sql
declare
  l_document_id adm_documents.document_id%type := 4711;
  l_user_id     adm_users.user_id%type;
  l_group_id    adm_groups.group_id%type;
begin
  adm_context_api.system_user_login('JDOE');
  select user_id  into l_user_id  from adm_users  where username   = 'ASMITH';
  select group_id into l_group_id from adm_groups where group_name = 'FINANCE';   -- stored upper case

  adm_shares_api.share_document(
    p_document_id => l_document_id
  , p_user_ids    => to_char(l_user_id)
  , p_groups_ids  => to_char(l_group_id)
  , p_share_role  => adm_access_control_api.c_view
  );
  for r_user in (select column_value as username from table(apex_t_varchar2('ASMITH', 'BWHITE'))) loop
    dbms_output.put_line(r_user.username
      || ' view=' || sys.diutil.bool_to_int(adm_access_control_api.user_is_allowed_to_view_document(
                       p_username => r_user.username, p_document_id => l_document_id))
      || ' edit=' || adm_access_control_api.user_has_edit_rights_on_document(
                       p_username => r_user.username, p_document_id => l_document_id));
  end loop;
  commit;
end;
/
```

Prints `view=1 edit=VIEW` for both. `share_folder(p_folder_id, ...)` takes the same arguments and covers the subtree.

### Publish a link with password and expiry, and open it as a stranger

```sql
declare
  l_document_id adm_documents.document_id%type := 4711;
  l_token       adm_document_link_shares.share_url_token%type;
begin
  adm_context_api.system_user_login('JDOE');
  adm_link_shares_api.create_document_link_share(
    p_document_id     => l_document_id
  , p_expiration_date => systimestamp + 14
  , p_share_role      => adm_access_control_api.c_view    -- c_edit lets the holder upload a version
  , p_password        => 'correct horse'                  -- null publishes an open link
  );
  select s.share_url_token
    into l_token
    from adm_document_link_shares s
   where s.document_id = l_document_id
   order by s.doc_link_share_id desc
   fetch first 1 row only;
  commit;                                                   -- hand out l_token, see the URL note below
end;
/
```

`get_share_url(p_share_url_token)` works only inside an APEX session of the ADM application: it returns
`/r/<workspace path prefix>/<app alias>/share-url-entry?p9010_share_url_token=<token>` with no host.
Outside a session (script, job) it returns `f?p=:9010:::::P9010_share_url_token:<token>` with an empty
app id, which no host prefix repairs: build the link from `l_token` for your landing page (ADM's is
page 9010, alias `SHARE-URL-ENTRY`).

The landing page has no ADM identity: redeem the token, then ask the check with it. The checks honour a
link (`p_share_url_token`) or embed token (`p_embed_token`) only when you pass it; the `adm_my_*_v` views
never do. `modify_document_link_share(p_doc_link_share_id, p_expiration_date, p_share_role)` later changes
expiry or role and keeps the token.

```sql
adm_context_api.clear_context;
l_token := '<token from the URL>';
adm_link_shares_api.check_credentials(   -- raises e_invalid_credentials or e_expired, audits the use
  p_share_url_token    => l_token
, p_password           => 'correct horse'
, po_document_id       => l_document_id
, po_doc_link_share_id => l_share_id
);
if adm_access_control_api.user_is_allowed_to_view_document(
     p_document_id => l_document_id, p_share_url_token => l_token) then
  null;   -- serve it; user_has_edit_rights_on_document with the same token tells if the link may edit
end if;
```

### Mint an embed token

```sql
adm_context_api.system_user_login('JDOE');               -- needs EDIT on the asset
l_token := adm_embed_api.get_or_create_document_token(   -- get_or_create_folder_token(p_folder_id => ...)
  p_document_id => 4711
, p_description => 'Case 2026-0042 viewer'
, p_expires_at  => systimestamp + 1
, p_is_readonly => 'Y'
);
-- signs only the context user (any user for an administrator); the hashes bind to p_session,
-- by default the current APEX session
l_params := adm_embed_api.get_item_values(p_embed_token => l_token, p_username => 'JDOE');
```

`p_permissions` (JSON) replaces `p_is_readonly`, for example `'{"grants":["DOWNLOAD","UPLOAD_VERSION"]}'`.
Grants: `DOWNLOAD UPLOAD UPLOAD_VERSION CREATE_FOLDER RENAME_FILE MOVE ZIP UNZIP DELETE` (DELETE needs
owner). Limits: `maxUploadBytes`, `allowedMimeTypes`, `maxDepth`, `visibility` (`ALL`/`OWN`),
`uploadQuota`. `"identity": "HOST"` lets the host application name the user (ADMIN to mint). Page setup:
<https://united-codes.com/products/apex-document-management/docs/dev/embedding/>

### Users and groups

```sql
adm_context_api.system_login;
select role_id into l_role_id from adm_roles where role_name = 'CONTRIBUTOR';   -- or ADMIN, VIEWER
adm_user_api.add_user(p_username => 'JDOE', p_role_id => l_role_id);            -- also creates home folder and trash
adm_group_api.create_group(p_group_name => 'Finance', p_description => 'Finance team', po_group_id => l_group_id);
select user_id into l_user_id from adm_users where username = 'JDOE';
adm_group_api.add_user_to_group(p_group_id => l_group_id, p_user_id => l_user_id);
```

The username must match what your APEX authentication signs in as. `remove_user_from_group(p_group_id, p_user_id)`
removes a member. `deactivate_user(p_username)` deletes every share to and from the user and blocks
`system_user_login`; `activate_user` does not bring the shares back.

## Errors

Test with `adm_error.is_no_permission(sqlcode)` and its siblings.

| Exception | Raised when |
| --- | --- |
| `e_no_permission` | no EDIT to share, publish or mint; login of a deactivated user |
| `e_admin_required` | user and group calls, `assert_admin`, a `HOST` token without ADMIN |
| `e_user_not_found`, `e_group_not_found` | unknown recipient id; `deactivate_user` of an unknown or inactive user |
| `e_share_invalid`, `e_already_exists` | share role is not `VIEW` or `EDIT`; the recipient already has a share |
| `e_invalid_credentials`, `e_expired` | `check_credentials`: bad token, password or lockout; past expiry |
| `e_embed_perm_invalid`, `e_embed_grant_unknown` | grant not enforceable (`SEARCH`) or payload malformed; unknown grant |
| `e_share_not_found`, `e_group_exists`, `e_user_exists`, `e_invalid_username` | unknown link share id; taken group name; user exists (any role); bad `add_user` name |

Guard your own administrative code with `adm_access_control_api.assert_admin(p_operation => '...')`. For
anything else, see the API reference or `user_arguments`
(`select argument_name, data_type, in_out, defaults from user_arguments where package_name = 'ADM_SHARES_API'`).
