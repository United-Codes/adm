# ADM examples and agent skills

Public examples, tutorial scripts, and customer agent skills for
[APEX Document Management (ADM)](https://united-codes.com/products/apex-document-management/).

Install ADM separately before you run the examples. This repository contains
integration examples; it does not contain the ADM product installer.

## Get the files

```sh
git clone https://github.com/United-Codes/adm.git
cd adm
```

## Examples

[Hooks demo app](examples/hooks-demo-app/README.md) is a sample APEX application
with upload rules, background workflows, retries, and a folder blueprint.
Its [tutorial scripts](examples/hooks-demo-app/tutorial/) accompany
[Build workflows on hooks](https://united-codes.com/products/apex-document-management/docs/tutorial/build-workflows-on-hooks/01-refuse-an-upload/).

The sample README lists the prerequisites and installation commands. The
application uses APEXlang; you can run the database tutorial without importing it.

## Agent skills

The [skills](skills/README.md) describe ADM's public APIs for coding agents.
From your project directory, install them with:

```sh
npx skills add United-Codes/adm
```

Start with `adm-plsql`, then use the skills for the domains you need.
The skills README explains installation options and states the ADM version they describe.

## Documentation and compatibility

- [ADM documentation](https://united-codes.com/products/apex-document-management/docs/)
- [Public API reference](https://united-codes.com/products/apex-document-management/docs/api/)
- [Hooks](https://united-codes.com/products/apex-document-management/docs/dev/hooks/)

Use the prerequisites in each example and the API reference for your installed
ADM version. The current examples include the customer hook error behavior
described in the hooks documentation: errors in `-20700` to `-20999` reach the
caller with their message. An older ADM installation can wrap those errors instead.

## License

The examples and skills in this repository are licensed under
[Apache License 2.0](LICENSE). ADM is a separate product with its own license.
