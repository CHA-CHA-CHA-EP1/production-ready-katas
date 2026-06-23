LANGUAGES  := go rust zig
SPEC_ROOT  := shared/assignment-specs

.PHONY: help sync check-sync

help:
	@echo "Usage:"
	@echo "  make sync        — create missing language folders based on shared/assignment-specs"
	@echo "  make check-sync  — show which language folders are missing (dry run, no changes)"

# Sync folder structure from shared/assignment-specs into every language folder.
# Safe to run multiple times — only creates what's missing, never deletes.
sync:
	@echo "Syncing $(SPEC_ROOT) → $(LANGUAGES)..."
	@find $(SPEC_ROOT) -mindepth 1 -type d | sed 's|$(SPEC_ROOT)/||' | while read dir; do \
		for lang in $(LANGUAGES); do \
			if [ ! -d "$$lang/$$dir" ]; then \
				mkdir -p "$$lang/$$dir"; \
				touch "$$lang/$$dir/.gitkeep"; \
				echo "  created: $$lang/$$dir"; \
			fi; \
		done; \
	done
	@find $(SPEC_ROOT) -name '*.md' | while read spec; do \
		dir=$$(dirname "$$spec" | sed 's|$(SPEC_ROOT)/||'); \
		kata=$$(basename "$$spec" .md); \
		for lang in $(LANGUAGES); do \
			if [ ! -d "$$lang/$$dir/$$kata" ]; then \
				mkdir -p "$$lang/$$dir/$$kata"; \
				touch "$$lang/$$dir/$$kata/.gitkeep"; \
				echo "  created: $$lang/$$dir/$$kata"; \
			fi; \
		done; \
	done
	@echo "Done."

# Dry run — show missing folders without creating anything.
check-sync:
	@missing=0; \
	for dir in $$(find $(SPEC_ROOT) -mindepth 1 -type d | sed 's|$(SPEC_ROOT)/||'); do \
		for lang in $(LANGUAGES); do \
			if [ ! -d "$$lang/$$dir" ]; then \
				echo "MISSING: $$lang/$$dir"; \
				missing=1; \
			fi; \
		done; \
	done; \
	for spec in $$(find $(SPEC_ROOT) -name '*.md'); do \
		dir=$$(dirname "$$spec" | sed 's|$(SPEC_ROOT)/||'); \
		kata=$$(basename "$$spec" .md); \
		for lang in $(LANGUAGES); do \
			if [ ! -d "$$lang/$$dir/$$kata" ]; then \
				echo "MISSING: $$lang/$$dir/$$kata"; \
				missing=1; \
			fi; \
		done; \
	done; \
	[ $$missing -eq 0 ] && echo "All language folders in sync."
