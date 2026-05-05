# betterbird-debian/Makefile
# This makefile requires GNU Make.

# Path to "thunderbird" source package tree
# (will not be modified, but must be pristine)
#
THUNDERBIRD_SOURCE = thunderbird-srcpkg

# Path to "thunderbird" package debian/ and thunderbird-l10n/ directories
# (usually inside the source package tree, but can be elsewhere)
#
THUNDERBIRD_DEBIAN = $(THUNDERBIRD_SOURCE)/debian
THUNDERBIRD_L10N   = $(THUNDERBIRD_SOURCE)/thunderbird-l10n

# Path to local Betterbird/thunderbird-patches Git repo
# (https://github.com/Betterbird/thunderbird-patches)
#
THUNDERBIRD_PATCHES = thunderbird-patches

# Uncomment this if you wish to modify $(THUNDERBIRD_DEBIAN), otherwise
# the conversion process will operate on a copy.
#
#INPLACE = 1

# Path to local betterbird-debian Git repo
# (https://salsa.debian.org/iskunk/betterbird-debian.git)
# (where this makefile comes from)
#
DEBIAN_CONVERT = .

# Append this to the Debian package version string
#
ADD_VERSION_SUFFIX =

# Target distribution (e.g. bookworm, jammy)
# If unset, the distribution will be set to UNRELEASED.
#
DISTRIBUTION = jammy

# Package maintainer (i.e. you) contact info
#
export DEBFULLNAME ?= Emmanuel Goldstein
export DEBEMAIL    ?= cereal@example.com

# List of patches to drop from the patch series to avoid conflicts.
# This list should be as short as possible; run the check-patch-drop-list
# target to verify this.
#
PATCH_DROP_LIST =

# These patches make edits that are either specific to Thunderbird, or
# superseded by the Betterbird patches in one way or another.
#
PATCH_DROP_LIST += \
	debian-hacks/all-thunderbird.js-Append-esr-to-VERSION-variable.patch \
	fixes/Appdata-Adding-some-German-translations.patch \
	fixes/Appdata-Fix-up-AppStream-error-by-adding-missing-field.patch

# Addresses the same issue as
# fixes/Add-missing-.gitmodules-files-which-are-needed-to-build-t.patch
#
PATCH_DROP_LIST += \
	betterbird/bugs/2006630-fix-gitmodules.patch

# List of patches to delete outright
#
PATCH_NUKE_LIST = \
	betterbird/branding/03-branding-mac.patch \
	betterbird/branding/04-branding.patch

DPKG_SOURCE ?= dpkg-source --abort-on-upstream-changes

# quilt(1) setup
#
QUILT = quilt --quiltrc /dev/null
export QUILT_DIFF_OPTS = -p
export QUILT_PATCHES = debian/patches
export QUILT_REFRESH_ARGS = -p ab --no-index --no-timestamps

TIME = env time -p

changelog = $(THUNDERBIRD_DEBIAN)/changelog
ifneq ($(wildcard $(changelog)),)
debian_version := $(shell dpkg-parsechangelog --file $(changelog) --show-field Version | sed 's/^1://')
upstream_version := $(shell echo '$(debian_version)' | sed -r 's/^[0-9]+://; s/-[^-]+$$//')
bb_version := $(shell echo '$(upstream_version)' | sed -r 's/\..*//')
ifndef URGENCY
URGENCY := $(shell dpkg-parsechangelog --file $(changelog) --show-field Urgency)
endif
endif

################

work := $(shell pwd)

ifdef INPLACE
bb_srcpkg = $(THUNDERBIRD_SOURCE)
bb_debian = $(THUNDERBIRD_DEBIAN)
else
bb_srcpkg = bb-srcpkg
bb_debian = $(bb_srcpkg)/debian
endif

tb_debian_dep  = $(THUNDERBIRD_DEBIAN)/source/format
bb_debian_dep  = $(bb_debian)/source/format
tb_patches_dep = $(THUNDERBIRD_PATCHES)/metadata/eu.betterbird.Betterbird.desktop

# Avoid weird locale-dependent sort orders
#
export LC_COLLATE = C

# A bit of tooling around quilt(1) to apply all patches and automatically
# refresh the ones which need it (unlike "quilt push -a --refresh", which
# refreshes everything unconditionally)
#
# https://savannah.nongnu.org/bugs/?63986
#
quilt_auto_refresh = \
	while :; do \
		(set -x; $(QUILT) push -afq --fuzz=0) | tee tmp.quilt.out; \
		! grep -q 'FAILED -- saving rejects' tmp.quilt.out || exit; \
		if tail -n 1 tmp.quilt.out | grep -q 'forced; needs refresh'; then \
			(set -x; $(QUILT) refresh) || exit; \
		else \
			tail -n 1 tmp.quilt.out | grep -q '^Now at patch' || exit; \
			break; \
		fi; \
	done \
	&& rm -f tmp.quilt.out

################

.PHONY: all
all: convert

.PHONY: convert
convert: stage-6.stamp

.PHONY: source-package
source-package: stage-7.stamp

################################
##
## Stage 1: PATCHES
##

stage-1.stamp: $(tb_debian_dep)
	test ! -f stage-2.stamp
	@$(MAKE) -f $(lastword $(MAKEFILE_LIST)) check-git_warning

ifndef INPLACE
	rm -rf bb-srcpkg
	mkdir bb-srcpkg
	cp -a $(THUNDERBIRD_DEBIAN)/ $(bb_debian)
endif
	touch $(bb_debian)/__BETTERBIRD_CONVERSION_INCOMPLETE__

# Copy over patches from the BB patches tree (minus the nuked ones)
	mkdir $(bb_debian)/patches/betterbird
	tar cf - -C $(THUNDERBIRD_PATCHES)/$(bb_version) \
		branding bugs cherrypicks features misc \
	| tar xf - -C $(bb_debian)/patches/betterbird
	cd $(bb_debian)/patches && rm -v $(PATCH_NUKE_LIST)

# Adjust file paths for patches that apply to comm/** (i.e. any patch file
# not named *-moz.patch)
	perl -pi \
		-e '$$not_moz = $$ARGV !~ /-moz\.patch$$/;' \
		-e 'if ($$not_moz && m!^(diff --git a/|--- a/|\+\+\+ b/|(copy|rename) (from|to) )!)' \
		-e '{ s!( (?:[ab]/)?)([-\w]+)/!$${1}comm/$$2/!g; }' \
		$(bb_debian)/patches/betterbird/*/*.patch

# Convert patches with Git binary diffs
	(cd $(THUNDERBIRD_PATCHES)/$(bb_version) \
	 && cat series-moz && echo && cat series) > tmp.series-bb
	$(DEBIAN_CONVERT)/patch-conv.sh $(bb_debian) tmp.series-bb
	rm tmp.series-bb

# Add newly-extracted binary files to the allow-list
	test -d $(bb_debian)/bb-resources
	find $(bb_debian)/bb-resources \
		-type f -printf 'debian/bb-resources/%P\n' \
	| sort \
	| grep -v '/README$$' \
	>> $(bb_debian)/source/include-binaries

# Comment out from the series the patches that should be dropped
	! grep '^#bb-drop#' $(bb_debian)/patches/series
	@for p in $(PATCH_DROP_LIST); do \
		echo "checking $$p"; \
		grep -v '^#' $(bb_debian)/patches/series \
		| awk '{ print $$1 }' | grep -Fqx "$$p" || exit; \
	done
	for p in $(PATCH_DROP_LIST); do \
		perl -pi -e '$$a=$$_; chomp($$a); $$a=~s/\s.*//; $$a eq "'"$$p"'" and s/^/#bb-drop#/' \
			$(bb_debian)/patches/series; \
	done

	touch $@

################################
##
## Stage 2: LANGPACKS
##

bb_langpack_update_url = https://www.betterbird.eu/downloads/LanguagePacks/updates.json

stage-2.stamp: stage-1.stamp $(bb_debian_dep)
	test ! -f stage-3.stamp

# Check that the content of the BB locale-specific scripts is as expected
	perl -ne 'BEGIN { $$path = qr![-\w.]{,32}(/[-\w.]{,32})*!; }' \
		-e '/^$$/ || /^#/' \
		-e '|| /^echo "([^"]|\\")+"\s+>> $$path$$/' \
		-e '|| /^sed -i -e .+ $$path$$/' \
		-e 'or die "error: unrecognized line at $$ARGV:$$.\n"' \
		$(THUNDERBIRD_PATCHES)/$(bb_version)/scripts/*.sh

# Prepare patched en-US branding files
	rm -rf bb-l10n-patched bb-branding
	cp -a $(THUNDERBIRD_L10N) bb-l10n-patched
	mkdir bb-branding
	(cd $(THUNDERBIRD_SOURCE)/comm \
	 && tar cf - mail/branding/thunderbird/locales/en-US/brand.* \
	) | tar xf - -C bb-branding
	cat \
		$(THUNDERBIRD_PATCHES)/$(bb_version)/branding/01-branding.patch \
		$(THUNDERBIRD_PATCHES)/$(bb_version)/branding/02-branding.patch \
	| (cd bb-branding && GIT_DIR=/dev/null git apply --include='**/brand.*' -)

# Iterate through all the langpacks. Any locale for which a BB script
# does not exist is unsupported by BB, and thus removed from the build
	for mf in bb-l10n-patched/*/manifest.json; do \
		locale=$$(echo $$mf | cut -d/ -f2); \
		locale_lc=$$(echo $$locale | tr A-Z a-z); \
		locale_sh=$(THUNDERBIRD_PATCHES)/$(bb_version)/scripts/$$locale.sh; \
		if [ ! -f $$locale_sh ]; then \
			echo "  removing locale \"$$locale\" ..."; \
			sed -ri \
				-e "/^Package: thunderbird-l10n-$$locale_lc\$$/,/^\$$/ d" \
				-e "/^\\s+thunderbird-l10n-$$locale_lc \(>= / d" \
				$(bb_debian)/control; \
			continue; \
		fi; \
		echo "converting locale \"$$locale\" ..."; \
		perl -pi \
			-e 's/"(langpack-\S{,8})\@thunderbird.mozilla.org"/"$$1\@betterbird.eu"/;' \
			-e 's/Thunderbird (Language Pack)/Betterbird $$1/;' \
			-e '/^(\s+)"id":.*langpack/ and $$_ .= "$$1\"update_url\": \"$(bb_langpack_update_url)\",\n"' \
			$$mf; \
		for file in $$(find bb-l10n-patched/$$locale -type f -name brand.\*); do \
			file_bn=$$(basename $$file); \
			cp bb-branding/mail/branding/betterbird/locales/en-US/$$file_bn $$file || exit; \
		done; \
		(cd bb-l10n-patched/$$locale && sh $$locale_sh) || exit; \
	done

# Generate unified patch to convert all the langpacks
	rm -f bb-l10n-orig
	ln -s $(THUNDERBIRD_L10N) bb-l10n-orig
	! git diff --no-index bb-l10n-orig/ bb-l10n-patched > tmp.langpacks.patch
	sed -r \
		-e '1i Betterbird language pack modifications\n' \
		-e '/^diff --git / d' \
		-e '/^index / d' \
		-e '/^(---|\+\+\+) / {' \
		-e 's! a/bb-l10n-orig/! a/thunderbird-l10n/!' \
		-e 's! b/bb-l10n-patched/! b/thunderbird-l10n/!' \
		-e '}' \
		tmp.langpacks.patch \
	> $(bb_debian)/patches/betterbird/langpacks.patch
	echo betterbird/langpacks.patch >> $(bb_debian)/patches/series

# Modify the rules file to process the langpacks correctly
	perl -pi -e 'BEGIN { $$q = "'"'"'" }' \
		-e '/^(\s+)for (LANG|XPI) in \*; do/ and' \
		-e '$$_ .= "$${1}\tgrep -q $$q\"id\":.*betterbird$$q \$$\$${$$2}/manifest.json || continue ;\\\n";' \
		-e '/preparing and working on/ and s/thunderbird/betterbird/g;' \
		-e 's:(debian|usr/(bin|lib))/thunderbird:$$1/betterbird:g' \
		$(bb_debian)/rules

	rm -rf bb-branding bb-l10n-orig bb-l10n-patched tmp.langpacks.patch
	touch $@

################################
##
## Stage 3: MISC FILES AND EDITS
##

bb_mozconfig = $(THUNDERBIRD_PATCHES)/$(bb_version)/mozconfig-Linux
bb_mozconfig_regex = '^\#\#\#\# Betterbird required build configuration'

delete_segment = \
	file=$(1); re0=$(2); re1=$(3); \
	grep -El "$$re0" $$file && \
	grep -El "$$re1" $$file && \
	sed -ri "/$$re0/,/$$re1/ d" $$file

stage-3.stamp: stage-2.stamp $(bb_debian_dep)
	test ! -f stage-4.stamp

# Create BB mozconfig, and refer to it from the top-level TB mozconfig
	grep -q $(bb_mozconfig_regex) $(bb_mozconfig)
	(echo '# Configuration extracted from'; \
	 echo '# Betterbird/thunderbird-patches/$(bb_version)/mozconfig-Linux' \
	) > $(bb_debian)/mozconfig.betterbird
	sed -n /$(bb_mozconfig_regex)/,'$$ p' $(bb_mozconfig) \
	| tail -n +2 >> $(bb_debian)/mozconfig.betterbird
	sed -i \
		-e '/topsrcdir\/mozconfig\.default/ { G' \
		-e 'a # sourcing Betterbird-specific settings' \
		-e 'a . $$topsrcdir/mozconfig.betterbird' -e '}' \
		$(bb_debian)/mozconfig.thunderbird

# Remove files not applicable to BB
	rm -v \
		$(bb_debian)/*.NEWS \
		$(bb_debian)/*.desktop \
		$(bb_debian)/*.maintscript \
		$(bb_debian)/gbp.conf \
		$(bb_debian)/watch
	rm -rv $(bb_debian)/logo
	sed -i '/^debian\/logo\// d' $(bb_debian)/source/include-binaries

# BB provides its own .desktop file
	cp $(THUNDERBIRD_PATCHES)/metadata/eu.betterbird.Betterbird.desktop \
		$(bb_debian)/
	sed -ri 's/^(Icon)=.*/\1=betterbird/' \
		$(bb_debian)/eu.betterbird.Betterbird.desktop

# Lintian fix
	! grep -q '^Priority:' $(bb_debian)/control
	sed -i '/^Package:/ a Priority: optional' $(bb_debian)/control

# Add libdbusmenu-gtk3-dev to Build-Depends: so that we can build the
# "betterbird-systray-icon" utility
	! grep -q '\blibdbusmenu-gtk3-dev\b' $(bb_debian)/control
	perl -pi \
		-e '/^(\s+)libclang-dev,$$/' \
		-e 'and $$_ .= "$${1}libdbusmenu-gtk3-dev,\n"' \
		$(bb_debian)/control

# Delete a whole tranche of profile-migration code in the wrapper script
# that does not apply to BB
	$(call delete_segment \
		,$(bb_debian)/thunderbird-wrapper.sh \
		,'^\#\s+User Thunderbird Profile Adoptions' \
		,'^\# If we are here we going simply further')

# Likewise preference migration code in the postinst script
	$(call delete_segment \
		,$(bb_debian)/thunderbird.postinst \
		,'^ {8}if \[ -d \$$\{ICEDOVE_PREF\} \]; then$$' \
		,'^ {8}fi$$')

# A *lot* of text in the Debian README is not applicable to BB
	sed -i '/^De-Branding of Icedove/,$$ d' $(bb_debian)/README.Debian

	touch $@

################################
##
## Stage 4: SEARCH AND REPLACE
##

# Note: Package description should not start with the package name
bb_description = "Soft fork of Mozilla Thunderbird. Simply better."

stage-4.stamp: stage-3.stamp $(bb_debian_dep) $(DEBIAN_CONVERT)/editcontrol.pl
	test ! -f stage-5.stamp

# Check that the description files are present and correctly formatted
	cd $(DEBIAN_CONVERT) \
	&& test -f description-main.txt && test -f description.txt \
	&& ! grep -nv '^ \S' description-main.txt description.txt

# General name swapping
	cd $(bb_debian) && sed -ri \
		-e 's/net\.thunderbird/eu.betterbird/g' \
		-e 's/thunderbird\.(desktop)/eu.betterbird.Betterbird.\1/g' \
		-e 's/THUNDERBIRD/BETTERBIRD/g' \
		-e 's/Thunderbird/Betterbird/g' \
		-e 's/thunderbird/betterbird/g' \
		*.1 \
		*.bash-completion \
		*.install \
		*.js \
		*.links \
		*.lintian-overrides \
		*.manpages \
		*.postinst \
		*.prerm \
		*.sh

# More selective swaps in the AppArmor files
	cd $(bb_debian)/apparmor && sed -ri \
		'/THUNDERBIRD_USER_DIR|cache/! s/thunderbird/betterbird/g' \
		usr.bin.thunderbird
	sed -i '/dh_apparmor/ s/thunderbird/betterbird/g' $(bb_debian)/rules

# Control file edits
	perl -pi -0777 \
		-e 's/^ Thunderbird is an mail client suitable .*(\n .*)+\n application using the XUL .*$$/ __BB_DESCRIPTION_MAIN__/gm;' \
		-e 's/^ Thunderbird is an mail client suitable .*(\n .*)+\n the XUL user interface .*$$/ __BB_DESCRIPTION__/gm' \
		$(bb_debian)/control
	$(DEBIAN_CONVERT)/editcontrol.pl -i \
		-e 'BEGIN { our $$desc = $(bb_description); } our $$desc;' \
		-e '$$field =~ /^(Source|Package|Breaks|Depends|Recommends|Replaces|Suggests)$$/ and s/\bthunderbird\b/betterbird/g;' \
		-e '$$field eq "Description" and s/\bThunderbird\b/Betterbird/g;' \
		-e '$$field eq "Description" && m:mail/news: and s:^.*:$$desc:;' \
		-e '$$field eq "Homepage" and s/thunderbird.net/betterbird.eu/;' \
		-e '$$field =~ /^(Uploaders|X-Debian-Homepage)$$/ and undef $$_;' \
		$(bb_debian)/control
	cd $(DEBIAN_CONVERT) && sed -i \
		-e '/^ __BB_DESCRIPTION_MAIN__/ {r description-main.txt' -e 'd}' \
		-e '/^ __BB_DESCRIPTION__/ {r description.txt' -e 'd}' \
		$(abspath $(bb_debian))/control

	touch $@

################################
##
## Stage 5: RENAME FILES
##

# Script that maps files from the original debian/ subdirectory to the
# new one, taking renames into account. The script can be run with the
# following variables set:
#
#   op1 = operation to perform on files which DO NOT change name
#   op2 = operation to perform on files which DO change name
#   debian_a = path to first debian/ subdirectory
#   debian_b = path to second debian/ subdirectory
#
debian-file-map.sh: $(bb_debian_dep)
	find $(bb_debian) -type f -printf '%P\n' \
	| grep -Ev -e '^patches/' -e '^__\w+_CONVERSION_INCOMPLETE__$$' \
	| sort \
	| perl -n \
		-e 'chomp; s,^,\$$debian/,; $$src=$$_;' \
		-e '!/mozconfig/ and s,thunderbird,betterbird,g;' \
		-e '$$n = $$_ eq $$src ? "1" : "2";' \
		-e '$$src =~ s/^(.debian)/$${1}_a/;' \
		-e 's/^(.debian)/$${1}_b/;' \
		-e 'print "\$$op$$n\t$$src\t$$_\n"' \
	> $@

stage-5.stamp: stage-4.stamp $(bb_debian_dep) debian-file-map.sh
	test ! -f stage-6.stamp

	cd $(bb_debian) \
	&& op1=: op2='mv -fv' debian_a=. debian_b=. sh -e $(CURDIR)/debian-file-map.sh
	rm $(bb_debian)/__BETTERBIRD_CONVERSION_INCOMPLETE__
	touch $@

	touch $@

################################
##
## Stage 6: PACKAGE PREP
##

stage-6.stamp: stage-5.stamp $(bb_debian_dep)
	test ! -f stage-7.stamp

# Edit the maintainer into the control file
	if ! grep '^Maintainer:' $(bb_debian)/control | grep -Fq '<$(DEBEMAIL)>'; \
	then \
		$(DEBIAN_CONVERT)/editcontrol.pl -i \
			-e 'if ($$field eq "Maintainer") { set_field("XSBC-Original-Maintainer", $$_); $$_="__BB_MAINTAINER__"; }' \
			$(bb_debian)/control || exit; \
		sed -i 's#__BB_MAINTAINER__#$(DEBFULLNAME) <$(DEBEMAIL)>#' \
			$(bb_debian)/control; \
		sed -i 's/^Xsbc-/XSBC-/' $(bb_debian)/control; \
	fi

# Create a package changelog entry
	test -n '$(debian_version)'
	cd $(bb_debian) && debchange \
		--no-conf \
		--changelog changelog \
		--package betterbird \
		--newversion $(debian_version)$(ADD_VERSION_SUFFIX) \
		--force-bad-version \
		$(if $(DISTRIBUTION),--distribution $(DISTRIBUTION)) \
		$(if $(URGENCY),--urgency $(URGENCY)) \
		--no-auto-nmu \
		'Apply Betterbird modifications.'

	touch $@

################################
##
## Stage 7: BUILD PACKAGE
##

tb_tarballs = \
	thunderbird_$(upstream_version).orig.tar.xz \
	thunderbird_$(upstream_version).orig-thunderbird-l10n.tar.xz

bb_tarballs = $(subst thunderbird_,betterbird_,$(tb_tarballs))

betterbird_$(upstream_version).%.tar.xz: thunderbird_$(upstream_version).%.tar.xz
	ln -s $< $@

stage-7.stamp: stage-6.stamp $(bb_debian_dep) $(bb_tarballs)
	$(DPKG_SOURCE) --build $(bb_srcpkg)
	touch $@
	ls -Ll betterbird_$(VERSION)*

################

## Checks

# Check that the $(THUNDERBIRD_PATCHES) Git repo is checked out to a commit
# matching $(upstream_version). This ensures that we are using the specific
# revision of the patches intended for the version of Thunderbird being
# converted here.
#
.PHONY: check-git check-git_warning
check-git check-git_warning: $(tb_patches_dep)
	@cd $(THUNDERBIRD_PATCHES) && git show -s >/dev/null 2>&1 || exit 0; \
	bbtag=$$(git describe --tags); \
	echo; \
	echo 'target Thunderbird version: $(upstream_version)'; \
	echo "    Betterbird patches tag: $$bbtag"; \
	echo; \
	case "$$bbtag" in '$(upstream_version)'-bb*) echo '==== $@ OK ===='; exit 0 ;; esac; \
	case $@ in \
		*_warning) \
		echo 'Warning: The patches are not matched to this version of Thunderbird. The conversion process may fail.' | fmt; \
		echo \
		;; \
		*) \
		echo 'Please checkout the appropriate Git tag in the thunderbird-patches repo.' | fmt; \
		echo; \
		exit 1 \
		;; \
	esac

# Check that every patch listed in PATCH_DROP_LIST needs to be dropped
# in order for the ungoogled-chromium patch series to apply cleanly.
# That is, verify that PATCH_DROP_LIST is minimal, so that we don't drop
# any patches unnecessarily.
#
# (All this does is attempt to apply the combined patch series multiple
# times, each time enabling one of the dropped patches, and verifying
# that the expected conflicts result.)
#
.PHONY: check-patch-drop-list
check-patch-drop-list: stage-2.stamp
	! find $(ug_source) -type f -name \*.rej | grep .
	: >tmp.check-pdl.out
	cd $(bb_debian)/patches && cp -p series series.check-pdl
	export QUILT_SERIES=series.check-pdl; \
	for p in $(PATCH_DROP_LIST); do \
		(cd $(bb_srcpkg) && set -x && $(QUILT) pop -afq); \
		echo "==== checking $$p drop ===="; \
		(cd $(bb_debian)/patches && cp -fp series $$QUILT_SERIES); \
		perl -pi -e '$$a=$$_; $$a =~ s/^#bb-drop#|\n$$//g; $$a eq "'"$$p"'" and $$_="$$a\n"' \
			$(bb_debian)/patches/$$QUILT_SERIES; \
		if (cd $(bb_debian) && set -x && $(QUILT) push -afq --fuzz=0); then \
			echo "==== $$p drop NOT NEEDED ===="; \
			echo "$$p: remove from PATCH_DROP_LIST" >>tmp.check-pdl.out; \
		else \
			echo "==== $$p drop OK ===="; \
		fi; \
	done
	find $(bb_srcpkg) -type f -name \*.rej -delete
	cd $(bb_srcpkg) && $(QUILT) pop  -afq
	rm -r $(bb_srcpkg)/.pc
	rm $(bb_debian)/patches/series.check-pdl
	cd $(bb_srcpkg) && $(QUILT) push -afq --fuzz=0
	@echo; ! grep . tmp.check-pdl.out
	rm -f tmp.check-pdl.out
	@echo '==== $@ OK ===='

.PHONY: check
check: check-git check-patch-drop-list

################

.PHONY: clean
clean:
	rm -f stage-?.stamp
	rm -f bb-l10n-orig
	rm -rf bb-branding
	rm -rf bb-l10n-patched
	rm -rf bb-srcpkg.orig.*
	rm -f debian-file-map.sh
	rm -rf tmp.*

.PHONY: clean-more
clean-more: clean
	rm -rf bb-srcpkg
	rm -f betterbird_*.debian.tar.xz
	rm -f betterbird_*.dsc

.DELETE_ON_ERROR:

# end betterbird-debian/Makefile
