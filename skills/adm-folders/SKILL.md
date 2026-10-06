---
name: adm-folders
description: >
  Builds and maintains the ADM (APEX Document Management) folder tree from PL/SQL with
  adm_folder_api: resolving a path to an id, creating nested folders idempotently, renaming,
  moving, trashing, restoring and permanently deleting folders, and what the trash does to a
  subtree and to its shares. Use for folder paths like /users/jdoe/..., a folder structure per
  case or customer, "undelete a folder", or an empty trash. Not for document files (see
  adm-documents) or access rules (see adm-sharing-and-permissions).
metadata:
  version: "26.2"
---

# Folders

Needs an established context and your own `commit` - see `adm-plsql`. Folders form one tree; each
has a `parent_folder_id` and a `folder_path`. ADM maintains the path, so derive ids from it and
never write it. `/` is the root. `/users/<name>` is a user's home and `/users/<name>/trash` is
their trash; both exist as soon as the user does.

## Gotchas

1. **`get_folder_id` is an exact match and never returns null.** The path is lowercase with no
   trailing slash (`/Cases` and `/cases/` both raise `e_folder_not_found`). It checks no
   permission, so it returns an id for a folder the caller cannot see. A trashed folder is found
   only under its trash path, `/users/<u>/trash/<name>_<timestamp>_<hash>`; the old path is free.
2. **"Create if missing" is a handler, not an `if`.** Catch `adm_error.e_folder_not_found`. A
   second `add_folder` with a taken name (case-insensitive) raises `e_folder_exists`.
3. **Edit rights are not enough for most changes.** `add_folder` needs EDIT on the parent, and
   `move_folder` needs EDIT on both parents. `rename_folder`, `trash_folder` and `restore_folder`
   need OWNER (or admin): a user with only an EDIT share can add subfolders but not rename or
   trash. A move between `/users/x` or `/groups/x` trees also needs OWNER.
4. **`p_is_system_folder => 'Y'` cannot be undone.** Any contributor can create one, and then
   nobody can rename, move, trash or delete it (`e_folder_system`). Leave it at `'N'`.
5. **`trash_folder` takes the caller's own name in `p_user_id`.** A non-admin who names someone
   else gets `e_folder_trash_rule`. Use `sys_context(adm_context_api.c_ctx_namespace,
   adm_context_api.c_ctx_username)`.
6. **Trashing revokes access and restore does not give it back.** Folder shares, document shares,
   link shares and embed tokens for the whole subtree are deleted. After `restore_folder` the
   subtree is back, but with no shares. Grant them again, and tell the users.
7. **The whole subtree goes to the trash, but only the folder you trashed is a trash root.** Only
   a root can be restored or permanently deleted (`e_folder_trash_rule` for any folder below it).
   The root keeps its original parent. If the old name is taken again, the folder returns as
   `<name>_restored_<yyyymmddhh24miss>`. If the old parent is itself in the trash, restore fails.
8. **`permanently_delete_folder` is for trash roots in your own trash.** A non-admin who names
   another user's trashed folder gets `e_no_permission`. If any document below is on legal hold
   or under retention, nothing is deleted and `e_folder_has_protected` is raised.
9. **Rename and move drop the embed tokens** that point into the old path, because tokens are
   keyed on a path. Internal shares survive. Both rewrite the paths of the whole subtree.
10. **You need no guard code for the structural rules.** The API refuses a move into the folder
    itself or a descendant (`e_folder_cycle`), into the trash (`e_folder_trash_rule`) and into
    the current parent (`e_invalid_state`). A document cannot be filed in the trash either.
11. **Names are validated.** `< > : " / \ | ? * ` and control characters, and a leading or
    trailing space, raise `e_invalid_name`. A null parent raises `e_missing_param`.
12. **`create_trash_folder` is a function that returns the id, and the trash already exists.** A
    call for a user who has one raises `e_folder_exists`. You almost never need it.
13. **Every `add_folder` fires the `AFTER_NEW_FOLDER_CREATION` hook** (see `adm-hooks`). A hook
    that creates folders must pass `p_run_hooks => false` (admin or system user only).

## Recipes

Create a nested path, safe to run again (replace the path):

```sql
declare
  l_folder_id adm_folders.folder_id%type;

  function ensure_folder_path (
    p_folder_path in varchar2
  ) return adm_folders.folder_id%type
  as
    l_parent_id adm_folders.folder_id%type := adm_folder_api.get_folder_id(p_folder_path => '/');
    l_path      varchar2(4000 char);
  begin
    for r in (
      select trim(s.column_value) as folder_name
        from table(apex_string.split(trim(both '/' from p_folder_path), '/')) s
    ) loop
      l_path := l_path || '/' || lower(r.folder_name);
      begin
        l_parent_id := adm_folder_api.get_folder_id(p_folder_path => l_path);
      exception
        when adm_error.e_folder_not_found then
          l_parent_id := adm_folder_api.add_folder(
            p_folder_name      => r.folder_name
          , p_parent_folder_id => l_parent_id
          );
      end;
    end loop;
    return l_parent_id;
  end ensure_folder_path;
begin
  adm_context_api.system_login;
  l_folder_id := ensure_folder_path('/cases/2026-0042/evidence');
  commit;
exception
  when others then
    rollback;
    raise;
end;
/
```

Rename, move, trash, restore, delete (ids are `adm_folders.folder_id` values):

```sql
adm_folder_api.rename_folder(p_folder_id => l_id, p_new_folder_name => 'acme-holdings');
adm_folder_api.move_folder(p_folder_id => l_id, p_new_parent_folder_id => l_new_parent_id);

adm_folder_api.trash_folder(
  p_folder_id => l_id
, p_user_id   => sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_username)
);
adm_folder_api.restore_folder(p_folder_id => l_id);    -- then re-share, see gotcha 6

-- the folder must be in the trash first
adm_folder_api.permanently_delete_folder(p_folder_id => l_id);
```

To find a trashed folder, select `adm_folders` where `trash_root_flag = 'Y'` and
`folder_path like '/users/<name>/trash/%'`. `is_parent_folder(p_potential_parent_id,
p_potential_child_id)` is true for the same folder, too.

## Errors

| Procedure | Raised for | Exception |
| --- | --- | --- |
| all | unknown folder or path (`add_folder`: also a trashed parent) | `e_folder_not_found` |
| `add_folder` | no EDIT on parent | `e_no_edit_right` |
| `add_folder`, `rename_folder`, `move_folder` | name taken in the parent | `e_folder_exists` |
| `rename_folder` | not OWNER | `e_no_permission` |
| `move_folder` | no EDIT on a parent / crossing owner trees without OWNER | `e_no_edit_right` / `e_no_permission` |
| `trash_folder`, `restore_folder` | not OWNER (restore: on the original parent) | `e_no_edit_right` |
| `trash_folder` | `p_user_id` is not the caller (non-admin) | `e_folder_trash_rule` |
| `permanently_delete_folder` | not admin and not in own trash | `e_no_permission` |
| system folder | rename, move, trash, delete | `e_folder_system` |
| `restore_folder`, `permanently_delete_folder` | not in the trash, not a trash root; restore also: old parent is trashed | `e_folder_trash_rule` |
| `move_folder` | into itself or a descendant | `e_folder_cycle` |
| `move_folder` | already in that parent | `e_invalid_state` |
| `add_folder`, `rename_folder` | forbidden character, leading or trailing space | `e_invalid_name` |
| `permanently_delete_folder` | document on hold or under retention | `e_folder_has_protected` |

Listing what is in a folder, for the current user only, is in `adm-querying`. For anything else,
read the API reference or query `user_arguments where package_name = 'ADM_FOLDER_API'`
(`argument_name, data_type, in_out, defaults`).
