# =============================================================================
#  ADM AI Chat Demo ("Ask questions across your documents") - project commands.
#  Run `make` to list them.
# =============================================================================

# `?=` means "unless already set", so override per call:  make install DB_CONN=my-connection
# Never put a trailing `# comment` on these lines: make keeps the whitespace between the value
# and the `#`, which silently passes a padded argument to sql.
SQL     ?= sql
DB_CONN ?= local-23ai-adm

.DEFAULT_GOAL := help
.PHONY: help precheck install teardown reset samples lesson-%
.NOTPARALLEL:

help: ## List the available commands
	@echo "ADM AI Chat Demo. Override variables like: make install DB_CONN=my-connection"
	@echo "Schema connection: $(DB_CONN)"
	@echo
	@grep -E '^[a-z][a-z%-]*:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*## "} {printf "  \033[1;36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo

precheck: ## Check the prerequisites (23ai, AI Pack, web credential, embedding and answer model)
	cd db && printf '@00_precheck.sql\nexit\n' | $(SQL) -name $(DB_CONN)

install: ## Install users, files, collections, index, tools and the first agent (re-runnable)
	cd db && printf '@install.sql\nexit\n' | $(SQL) -name $(DB_CONN)

teardown: ## Remove everything the demo created, including the collections and their vectors
	cd db && printf '@99_aic_teardown.sql\nexit\n' | $(SQL) -name $(DB_CONN)

reset: teardown install ## Teardown, then install again from scratch

lesson-%: ## Run one lesson script by its number, e.g. make lesson-10 (needs a fresh session each time)
	cd db && f=$$(ls $*_aic_*.sql | head -1) && printf '@%s\nexit\n' "$$f" | $(SQL) -name $(DB_CONN)

samples: ## Regenerate the sample PDFs and the generated load script (needs reportlab, poppler, ImageMagick)
	cd samples && python3 generate_samples.py && python3 generate_load_script.py
