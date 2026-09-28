.PHONY: check shellcheck bootstrap deploy web backup validate
check:
	./scripts/check-local.fish
	bash -n scripts/*.sh scripts/lib/*.sh
	git diff --check
shellcheck:
	shellcheck scripts/*.sh scripts/lib/*.sh
backup:
	./scripts/backup-node2.fish "$${NODE2_HOST:-node2}"
validate:
	./scripts/validate-node2.fish "$${NODE2_HOST:-node2}"
bootstrap:
	./scripts/bootstrap-node2.fish "$${NODE2_HOST:-node2}"
deploy:
	./scripts/deploy-node2.fish "$${NODE2_HOST:-node2}"
web:
	./scripts/configure-web.fish "$${NODE2_HOST:-node2}"
