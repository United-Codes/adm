---
name: adm-folders
description: >
  Building and maintaining the ADM (APEX Document Management) folder hierarchy from PL/SQL -
  adm_folder_api: resolving a path to a folder id, creating nested structures, renaming,
  moving, trashing, restoring and permanently deleting folders, and how the trash works on a
  subtree. Use whenever a task involves ADM folders, folder paths like /users/jdoe/...,
  creating a directory structure for a case or a customer, or the ADM trash. Read the
  adm-plsql skill first for the context and transaction rules.
---

# Folders

Needs an established context and your own `commit` — see the `adm-plsql` skill.

Folders (`adm_folders`) form a single tree with a **path** (`folder_path`) as well as a
`parent_folder_id`. The path is maintained by ADM; treat it as read-only and derive ids from it.

Conventions worth knowing before you create anything:

- `/` is the repository root.
- `/users/<lowercase name>` is a user's home folder, and `/users/<name>/trash` is their trash.
  Both are system folders — do not build your own structure inside `/users`.
- A **group folder** is owned by an ADM group; every member gets access through the group rather
  than through a share.
- Names are case-insensitive for uniqueness within a parent.

## Resolve a path to an id

```sql
l_folder_id := adm_folder_api.get_folder_id(p_folder_path => '/projects/acme');
```

It **raises** `adm_error.e_folder_not_found` when the path does not exist rather than returning
null, so a "create if missing" step is a handler, not an `if`:

```sql
declare
  l_folder_id adm_folders.folder_id%type;
begin
  begin
    l_folder_id := adm_folder_api.get_folder_id('/projects/acme');
  exception
    when adm_error.e_folder_not_found then
      l_folder_id := adm_folder_api.add_folder(
        p_folder_name      => 'acme'
      , p_parent_folder_id => adm_folder_api.get_folder_id('/projects')
      );
  end;
end;
/
```

## Create folders

`add_folder` exists as a function (returns the new id — use this one) and as a procedure for when
you genuinely do not need the id.

```sql
l_id := adm_folder_api.add_folder(
  p_folder_name      => 'contracts'
, p_parent_folder_id => l_parent_id
);
```

- EDIT rights on the parent are required.
- `p_is_system_folder` defaults to `'N'`. **Leave it there.** System folders are ADM's own
  scaffolding (`/users`, a trash folder); marking yours as one changes how the UI and the trash
  treat it.
- Creating a folder fires the `AFTER_NEW_FOLDER_CREATION` hook (see `adm-hooks`).

A whole structure, idempotently — the pattern most integrations need:

```sql
declare
  l_parent_id adm_folders.folder_id%type;
  l_child_id  adm_folders.folder_id%type;
  l_id        adm_folders.folder_id%type;

  function get_or_create (
    p_name      in adm_folders.folder_name%type
  , p_parent_id in adm_folders.folder_id%type
  , p_path      in varchar2
  ) return adm_folders.folder_id%type
  as
  begin
    return adm_folder_api.get_folder_id(p_path);
  exception
    when adm_error.e_folder_not_found then
      return adm_folder_api.add_folder(
        p_folder_name      => p_name
      , p_parent_folder_id => p_parent_id
      );
  end get_or_create;
begin
  adm_context_api.system_login;

  l_parent_id := get_or_create('cases', adm_folder_api.get_folder_id('/'), '/cases');
  l_child_id  := get_or_create('2026-0042', l_parent_id, '/cases/2026-0042');

  for r in (select 'evidence' as n from dual union all select 'correspondence' from dual) loop
    l_id := get_or_create(r.n, l_child_id, '/cases/2026-0042/' || r.n);
  end loop;

  commit;
end;
/
```

## Rename and move

```sql
adm_folder_api.rename_folder(p_folder_id => 99, p_new_folder_name => 'acme-holdings');
adm_folder_api.move_folder(p_folder_id => 99, p_new_parent_folder_id => 42);
```

Both rewrite the paths of the whole subtree, and both drop the embed tokens that pointed into the
old path (those are keyed on a path, so they would otherwise resolve against whatever appears
there next). Internal shares survive.

Before moving, guard against moving a folder into its own descendant — that would detach the
subtree from the tree:

```sql
if adm_folder_api.is_parent_folder(
     p_potential_parent_id => l_folder_id
   , p_potential_child_id  => l_target_id
   ) then
  raise_application_error(-20700, 'Cannot move a folder into its own subtree');
end if;
```

## Trash, restore, delete

```sql
adm_folder_api.trash_folder(p_folder_id => 99, p_user_id => 'JDOE');
adm_folder_api.restore_folder(p_folder_id => 99);
adm_folder_api.permanently_delete_folder(p_folder_id => 99);
```

How the trash behaves on a subtree, because this is where custom code goes wrong:

- `trash_folder` marks **the whole subtree** — every descendant folder and every document below it
  — with `deleted_flag = 'Y'`. So `deleted_flag` everywhere means "is in the trash", not "was
  deleted individually".
- Only the folder you trashed becomes a **trash root** (`trash_root_flag = 'Y'`) and remembers its
  original parent. It is therefore the only row in that subtree that can be restored.
  `restore_folder` on a folder that merely fell into the trash with an ancestor raises
  `adm_error.e_folder_trash_rule` — restore the root and the subtree comes back with it.
- `permanently_delete_folder` deletes the subtree through
  `adm_document_api.permanently_delete_document`, so stored content, tags and shares go too. If
  **any** document below is under legal hold or retention, it raises
  `adm_error.c_err_folder_has_protected` and deletes nothing.

Two guards you may need yourself:

```sql
-- Never create or move live content into a trash folder: it becomes invisible in the
-- listings and can be neither restored (it is not deleted) nor permanently deleted.
if adm_folder_api.is_trash_folder(p_folder_id => l_target_id) then
  raise_application_error(-20700, 'Refusing to file into the trash');
end if;
```

`adm_folder_api.create_trash_folder(p_username => 'JDOE')` exists for provisioning a user's trash;
ADM creates it on demand, so you rarely need to call it.

## Errors worth catching

| Situation | Exception |
| --- | --- |
| No such folder / path, or it is in the trash | `adm_error.e_folder_not_found` |
| Caller may not see it | `adm_error.e_no_view_right` |
| Caller may not write in it | `adm_error.e_no_permission` |
| Restoring a non-root, or into the trash | `adm_error.e_folder_trash_rule` |
| A name already taken in the parent | `adm_error.e_folder_exists` |
| Subtree holds a document on hold / under retention | `adm_error.e_folder_has_protected` |

To list what is *in* a folder — and only what the current user may see — use the SQL macros
described in the `adm-querying` skill rather than querying `adm_folders` yourself.
