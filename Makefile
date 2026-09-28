.PHONY: check shellcheck backup validate
check:
	./scripts/check-local.fish
	bash -n scripts/*.sh
	git diff --check
shellcheck:
	shellcheck scripts/*.sh scripts/lib/*.sh
backup:
	./scripts/backup-node2.fish "$${NODE2_HOST:-node2}"
validate:
	./scripts/validate-node2.fish "$${NODE2_HOST:-node2}"
