.PHONY: lint test check

lint:
	bash -n pi-clean.sh
	bash -n install.sh
	bash -n uninstall.sh
	shellcheck pi-clean.sh install.sh uninstall.sh tests/test_helper.bash

test:
	bats tests/pi-clean.bats

check: lint test
