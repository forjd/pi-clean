.PHONY: lint test check

lint:
	bash -n pi-clean.sh
	shellcheck pi-clean.sh tests/test_helper.bash

test:
	bats tests/pi-clean.bats

check: lint test
