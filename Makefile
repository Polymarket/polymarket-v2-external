.PHONY: setup coverage storage-check sizes wrap-check

setup:
	git config core.hooksPath .hooks

coverage:
	@./bash/check-coverage.sh

storage-check:
	@./bash/check-storage-layout.sh

sizes:
	@./bash/check-contract-sizes.sh

wrap-check:
	@./bash/check-wrap-discipline.sh
