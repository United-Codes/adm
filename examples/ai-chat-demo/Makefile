# =============================================================================
#  ADM AI Chat Demo ("Ask questions across your documents") - project commands.
#  Run `make` to list them.
# =============================================================================

# `?=` means "unless already set", so override per call:  make install DB_CONN=my-connection
# Never put a trailing `# comment` on these lines: make keeps the whitespace between the value
# and the `#`, which silently passes a padded argument to sql.
SQL     ?= sql
DB_CONN ?= local-23ai-adm

# Lesson 7: a DBA connection (only for the demo schema AIC_APP), the connection of the application
# schema, and the path of the UC AI install file (install_uc_ai_complete.sql of a UC AI release).
# The default APP_CONN carries the demo password of db/22_aic_app_schema.sql: a local database only.
DBA_CONN      ?= local-23ai-sys
APP_CONN      ?= aic_app/Aic-App-Demo-2026@localhost:1521/FREEPDB1
UC_AI_INSTALL ?=

# The chat app (lesson 4): APP_ID picks the app to export, APP is the APEXLANG folder.
APP_ID  ?= 218
APP_DIR ?= .
APP     ?= chat-app

.DEFAULT_GOAL := help
.PHONY: help precheck install policies teardown reset samples apex-users app-validate app-import app-export lesson-% app-schema app-uc-ai app-lesson-% app-teardown
.NOTPARALLEL:

help: ## List the available commands
	@echo "ADM AI Chat Demo. Override variables like: make install DB_CONN=my-connection"
	@echo "Schema connection: $(DB_CONN)"
	@echo
	@grep -E '^[a-z][a-z%-]*:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*## "} {printf "  \033[1;36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo

precheck: ## Check the prerequisites (23ai, AI Pack, web credential, embedding and answer model)
	cd db && printf '@00_precheck.sql\nexit\n' | $(SQL) -name $(DB_CONN)

install: ## Install users, files, the collection aic_contracts, index, tools and the first agent (re-runnable)
	cd db && printf '@install.sql\nexit\n' | $(SQL) -name $(DB_CONN)

policies: ## Lesson 1 in SQL: create and index the collection aic_policies (instead of the RAG collection manager)
	cd db && printf '@03b_aic_policies.sql\nexit\n' | $(SQL) -name $(DB_CONN)

teardown: ## Remove everything the demo created, including the collections and their vectors
	cd db && printf '@99_aic_teardown.sql\nexit\n' | $(SQL) -name $(DB_CONN)

reset: teardown install ## Teardown, then install again from scratch

apex-users: ## Lesson 4: create the APEX accounts AIC_LEGAL and AIC_HR (demo password, local schema only)
	cd db && printf '@18_aic_apex_users.sql\nexit\n' | $(SQL) -name $(DB_CONN)

app-validate: ## Lesson 4: check the APEXlang source of the chat app without importing it
	printf 'apex validate -input %s\nexit\n' '$(CURDIR)/$(APP_DIR)/$(APP)' | $(SQL) -name $(DB_CONN)

app-import: ## Lesson 4: import the chat app (application 218) into the workspace
	@test -d $(APP_DIR)/$(APP) || { echo "$(APP_DIR)/$(APP) not found - set APP=<folder>"; exit 1; }
	printf 'apex import -input %s\nexit\n' '$(CURDIR)/$(APP_DIR)/$(APP)' | $(SQL) -name $(DB_CONN)

app-export: ## Export the chat app from the database back into the APEXLANG folder
	rm -rf $(CURDIR)/temp-export && mkdir $(CURDIR)/temp-export
	printf 'apex export -applicationid %s -exptype APEXLANG -dir %s -overwrite-files -exitwhendone\n' \
	  '$(APP_ID)' '$(CURDIR)/temp-export' | $(SQL) -name $(DB_CONN)
	rsync -a --delete $(CURDIR)/temp-export/*/ $(CURDIR)/$(APP_DIR)/$(APP)/
	rm -rf $(CURDIR)/temp-export

lesson-%: ## Run one lesson script by its number, e.g. make lesson-10 (each script gets its own session)
	cd db && f=$$(ls $*_aic_*.sql | head -1) && printf '@%s\nexit\n' "$$f" | $(SQL) -name $(DB_CONN)

app-schema: ## Lesson 7, as a DBA: create the demo application schema AIC_APP in the workspace of the ADM schema
	cd db && printf '@22_aic_app_schema.sql\nexit\n' | $(SQL) -name $(DBA_CONN)

app-uc-ai: ## Lesson 7: install UC AI into AIC_APP (UC_AI_INSTALL=<path>), then its empty APEX application
	@test -n "$(UC_AI_INSTALL)" || { echo "Set UC_AI_INSTALL=<path to install_uc_ai_complete.sql>"; exit 1; }
	cd $(dir $(abspath $(UC_AI_INSTALL))) && printf '@%s\nexit\n' '$(notdir $(UC_AI_INSTALL))' | $(SQL) '$(APP_CONN)'
	cd db && printf '@22b_aic_app_application.sql\nexit\n' | $(SQL) '$(APP_CONN)'

app-lesson-%: ## Lesson 7: run a script as the application schema, e.g. make app-lesson-27
	cd db && f=$$(ls $*_aic_*.sql | head -1) && printf '@%s\nexit\n' "$$f" | $(SQL) '$(APP_CONN)'

app-teardown: ## Lesson 7: remove the lesson objects from AIC_APP, then drop AIC_APP as a DBA
	cd db && printf '@98_aic_app_teardown.sql\nexit\n' | $(SQL) '$(APP_CONN)'
	cd db && printf '@97_aic_app_schema_drop.sql\nexit\n' | $(SQL) -name $(DBA_CONN)

samples: ## Regenerate the sample PDFs and the generated load script (needs reportlab, poppler, ImageMagick)
	cd samples && python3 generate_samples.py && python3 generate_load_script.py
