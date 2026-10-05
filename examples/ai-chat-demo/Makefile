# =============================================================================
#  ADM AI Chat Demo ("Ask questions across your documents") - project commands.
#  Run `make` to list them.
# =============================================================================

# `?=` means "unless already set", so override per call:  make install DB_CONN=my-connection
# Never put a trailing `# comment` on these lines: make keeps the whitespace between the value
# and the `#`, which silently passes a padded argument to sql.
SQL     ?= sql
DB_CONN ?= local-23ai-adm

# The chat app (lesson 4): APP_ID picks the app to export, APP is the APEXLANG folder.
APP_ID  ?= 218
APP_DIR ?= .
APP     ?= chat-app

.DEFAULT_GOAL := help
.PHONY: help precheck install teardown reset samples apex-users app-validate app-import app-export lesson-%
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

install: ## Install users, files, collections, index, tools and the first agent (re-runnable)
	cd db && printf '@install.sql\nexit\n' | $(SQL) -name $(DB_CONN)

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

samples: ## Regenerate the sample PDFs and the generated load script (needs reportlab, poppler, ImageMagick)
	cd samples && python3 generate_samples.py && python3 generate_load_script.py
