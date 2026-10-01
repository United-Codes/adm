# =============================================================================
#  ADM Hooks Demo - project commands. Run `make` to list them.
# =============================================================================

# --- Configuration -----------------------------------------------------------
# `?=` means "unless already set", so any of these can be overridden per call:
#   make db-install DB_CONN=my-adm-connection
#
# Never put a trailing `# comment` on these lines: make keeps the whitespace
# between the value and the `#` as part of the value, which silently passes a
# padded argument to sql.

# The SQLcl executable. Some machines only have it as `sqlcl`.
SQL       ?= sql
# SQLcl saved connection of the ADM schema owner (no credentials live in here).
DB_CONN   ?= local-23ai-adm
# SQLcl saved connection of a DBA, used once for the Advanced Queuing grants.
DBA_CONN  ?= local-23ai-sys
# The schema that owns ADM, so the grants know who to give them to.
ADM_SCHEMA ?= ADM

# APEX app export/import. APP_ID picks the app to export; APP is the folder the
# APEXLANG export creates underneath APP_DIR - it is the app alias, lowercased.
APP_ID    ?= 217
APP_DIR   ?= .
APP       ?= hooks-demo

# --- Make behaviour ----------------------------------------------------------
# A bare `make` lists the commands instead of running the first one.
.DEFAULT_GOAL := help
.PHONY: help db-grants db-install db-uninstall app-validate app-import app-export install
# Nothing here benefits from parallelism, and two targets sharing a schema is bad.
.NOTPARALLEL:

# --- Help --------------------------------------------------------------------

help: ## List the available commands
	@echo "ADM Hooks Demo. Override variables like: make install DB_CONN=my-connection"
	@echo "Schema connection: $(DB_CONN)   DBA connection: $(DBA_CONN)   App id: $(APP_ID)"
	@echo
	@grep -E '^[a-z][a-z-]*:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*## "} {printf "  \033[1;36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo

# --- Database ----------------------------------------------------------------

db-grants: ## One time, as a DBA: grant the ADM schema Advanced Queuing (dbms_aq, dbms_aqadm)
	printf '@db/00_dba_grants.sql %s\nexit\n' '$(ADM_SCHEMA)' | $(SQL) -name $(DBA_CONN)

db-install: ## Install tables, queue, packages and register the three hooks (re-runnable)
	printf '@db/install.sql\nexit\n' | $(SQL) -name $(DB_CONN)

db-uninstall: ## Unregister the hooks and drop everything the demo created
	printf '@db/99_hkd_uninstall.sql\nexit\n' | $(SQL) -name $(DB_CONN)

# --- APEX application --------------------------------------------------------

app-validate: ## Check the APEXlang source without importing it
	printf 'apex validate -input %s\nexit\n' '$(CURDIR)/$(APP_DIR)/$(APP)' | $(SQL) -name $(DB_CONN)

app-import: ## Import the APEXlang folder into the workspace
	@test -d $(APP_DIR)/$(APP) || { echo "$(APP_DIR)/$(APP) not found - set APP=<folder>"; exit 1; }
	printf 'apex import -input %s\nexit\n' '$(CURDIR)/$(APP_DIR)/$(APP)' | $(SQL) -name $(DB_CONN)

app-export: ## Export the app from the database back into the APEXlang folder
	printf 'apex export -applicationid %s -exptype APEXLANG -dir %s -overwrite-files -exitwhendone\n' \
	  '$(APP_ID)' '$(CURDIR)/$(APP_DIR)' | $(SQL) -name $(DB_CONN)

install: db-install app-import ## Database objects, then the app
