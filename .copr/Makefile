# COPR runs this target as root inside its source-package build environment.
.PHONY: srpm
repo_dir := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

srpm:
	test -n "$(outdir)"
	dnf -y install make rpm-build rpmdevtools perl git-core patch cpio tar xz curl zip unzip python3
	$(MAKE) -C "$(repo_dir)" check
	$(MAKE) -C "$(repo_dir)" srpm outdir="$(outdir)"
