# GNU Make converts Fedora's Thunderbird packaging to Betterbird.
.DEFAULT_GOAL := srpm
.SHELLFLAGS := -ec
export LC_ALL := C

# Fedora tracks monthly releases. Use its last 153 spec with the exact ESR
# source and locale data used by the stable Betterbird release.
SRC_RPM = thunderbird-153.0.2-2.fc45.src.rpm
FEDORA_SOURCE_URL = https://kojipkgs.fedoraproject.org/packages/thunderbird/153.0.2/2.fc45/src/$(SRC_RPM)
TB_VERSION = 153.4.0
TB_SOURCE_VERSION = $(TB_VERSION)esr
TB_BUILD = 1
TB_SOURCE_URL = https://archive.mozilla.org/pub/thunderbird/candidates/$(TB_SOURCE_VERSION)-candidates/build$(TB_BUILD)
BB_VERSION = 153
BB_TAG = 153.4.0esr-bb10
BB_COMMIT = d5a1998bc257bee885330d5cc00926737472b2d6
BB_RELEASE_TAG = bb10
THUNDERBIRD_PATCHES = upstream-patches
PACKAGER = Betterbird Fedora packaging
PATCH_DROP_LIST =
PATCH_PLATFORM_DROP_LIST = branding/03-branding-mac.patch branding/04-branding.patch
# Patches from patches/, applied in comm/ after the Betterbird series.
# linux-systray-all-architectures.patch:
#   https://github.com/Betterbird/thunderbird-patches/pull/623
LOCAL_PATCHES = linux-systray-all-architectures.patch

PATCH_DIR = $(THUNDERBIRD_PATCHES)/$(BB_VERSION)
SOURCE_ARCHIVE = thunderbird-$(TB_SOURCE_VERSION).source.tar.xz
langpack_base = thunderbird-langpacks-$(TB_SOURCE_VERSION)-build$(TB_BUILD)
bb_langpack_base = betterbird-langpacks-$(TB_SOURCE_VERSION)-build$(TB_BUILD)
bb_spec = bb-tree/SPECS/betterbird.spec
locales = cs de en-GB es-ES fr it ja nl pl pt-BR pt-PT ru sv-SE uk zh-CN
locale_files = $(addprefix downloads/langpacks/,$(addsuffix .xpi,$(locales)))
bb_mozconfig_marker = ^\#\#\#\# Betterbird required build configuration
outdir ?= $(CURDIR)
rpm_args = --define "_topdir $(CURDIR)/bb-tree" \
	--define "_srcrpmdir $(abspath $(outdir))" \
	--define "_sourcedir $(CURDIR)/bb-tree/SOURCES" \
	--define "_specdir $(CURDIR)/bb-tree/SPECS"

.PHONY: all srpm source-package convert fetch check-inputs check-patches check prep verify clean FORCE
all source-package: srpm
srpm: stage-5.stamp
	rpmspec -P $(bb_spec) > /dev/null
	mkdir -p "$(outdir)"
	rpmbuild -bs $(rpm_args) $(bb_spec)
convert: stage-5.stamp
fetch: $(SRC_RPM) $(SOURCE_ARCHIVE) $(locale_files) $(THUNDERBIRD_PATCHES)/.git

# Download source code and localization data only. Partial files are never
# accepted as completed downloads.
$(SRC_RPM):
	curl --fail --location --retry 3 $(FEDORA_SOURCE_URL) -o $@.part
	mv $@.part $@
$(SOURCE_ARCHIVE):
	curl --fail --location --retry 3 $(TB_SOURCE_URL)/source/$@ -o $@.part
	mv $@.part $@
downloads/langpacks/%.xpi:
	mkdir -p $(@D)
	curl --fail --location --retry 3 $(TB_SOURCE_URL)/linux-x86_64/xpi/$*.xpi -o $@.part
	mv $@.part $@
$(THUNDERBIRD_PATCHES)/.git:
	git clone --depth 1 --branch $(BB_TAG) https://github.com/Betterbird/thunderbird-patches.git $(THUNDERBIRD_PATCHES)

check-inputs: fetch
	sha512sum --check sources.sha512
	@test "$$(git -C $(THUNDERBIRD_PATCHES) rev-parse HEAD)" = "$(BB_COMMIT)" || \
		{ echo 'error: patches must be at $(BB_TAG) ($(BB_COMMIT))' >&2; exit 1; }
	@test -z "$$(git -C $(THUNDERBIRD_PATCHES) status --porcelain --untracked-files=no)" || \
		{ echo 'error: Betterbird patches contain local changes' >&2; exit 1; }
	@test "$$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' $(SRC_RPM))" = thunderbird-153.0.2-2.fc45 || \
		{ echo 'error: expected Fedora thunderbird-153.0.2-2.fc45 source package' >&2; exit 1; }

check-patches: check-inputs
	@set -e; for s in series series-moz; do \
		awk '!/^#/ && NF {print $$1}' $(PATCH_DIR)/$$s | while read -r p; do \
			test -f "$(PATCH_DIR)/$$p" || { echo "error: missing patch $$p" >&2; exit 1; }; \
		done; \
	done
	@set -e; for p in $(PATCH_DROP_LIST) $(PATCH_PLATFORM_DROP_LIST); do \
		awk '!/^#/ && NF {print $$1}' $(PATCH_DIR)/series $(PATCH_DIR)/series-moz | \
			grep -Fx "$$p" > /dev/null || { echo "error: inactive dropped patch $$p" >&2; exit 1; }; \
	done
check: check-patches
	python3 -m unittest discover -s tests -v

# A changed command-line variable must not reuse another conversion's stamps.
tmp.inputs: FORCE
	@printf '%s\n' '$(SRC_RPM)' '$(TB_VERSION)' '$(TB_SOURCE_VERSION)' '$(TB_BUILD)' \
		'$(BB_VERSION)' '$(BB_TAG)' '$(BB_COMMIT)' '$(BB_RELEASE_TAG)' \
		'$(THUNDERBIRD_PATCHES)' '$(PACKAGER)' '$(PATCH_DROP_LIST)' \
		'$(PATCH_PLATFORM_DROP_LIST)' '$(LOCAL_PATCHES)' > $@.new
	@cmp -s $@.new $@ && rm $@.new || mv $@.new $@

src.unpack: $(SRC_RPM) Makefile | check-inputs
	rm -rf $@
	mkdir $@
	rpm2cpio $(SRC_RPM) | (cd $@ && cpio -idm --quiet)
	touch $@

stage-1.stamp: src.unpack $(SOURCE_ARCHIVE) Makefile sources.sha512 tmp.inputs \
		$(addprefix patches/,$(LOCAL_PATCHES)) | check-patches
	rm -rf bb-tree/SPECS bb-tree/SOURCES
	mkdir -p bb-tree/SPECS bb-tree/SOURCES
	cp -a --reflink=auto src.unpack/. bb-tree/SOURCES/
	mv bb-tree/SOURCES/thunderbird.spec $(bb_spec)
	cp --reflink=auto $(SOURCE_ARCHIVE) bb-tree/SOURCES/
	# The launchers contain executable names and installation paths too.
	for f in thunderbird.sh.in thunderbird-wayland.sh.in thunderbird-wayland.desktop thunderbird-redhat-default-prefs.js; do \
		sed -e 's/thunderbird/betterbird/g' -e 's/Thunderbird/Betterbird/g' \
			-e 's/@betterbird.mozilla.org/@betterbird.eu/g' \
			"src.unpack/$$f" > "bb-tree/SOURCES/$$(echo $$f | sed s/thunderbird/betterbird/)"; \
	done
	# Packaged language packs live in the application directory. The Fedora
	# launcher must not remove or replace Thunderbird's profile extensions.
	perl -0777 -pi -e 's/^MOZ_(LANGPACKS_DIR|EXTENSIONS_PROFILE_DIR)=.*\n//mg; s/^export MOZ_ALLOW_DOWNGRADE=1\n//mg; s/^##\n## Automatically installed langpacks.*?(?=^# BEAST fix)//ms' bb-tree/SOURCES/betterbird.sh.in
	mkdir bb-tree/SOURCES/bb-patches
	(cd $(PATCH_DIR) && tar cf - series series-moz branding bugs cherrypicks features misc) | \
		(cd bb-tree/SOURCES/bb-patches && tar xf -)
	for p in $(PATCH_DROP_LIST) $(PATCH_PLATFORM_DROP_LIST); do \
		for s in bb-tree/SOURCES/bb-patches/series bb-tree/SOURCES/bb-patches/series-moz; do \
			P=$$p perl -pi -e '$$a=$$_; chomp($$a); $$a=~s/\s.*//; $$a eq $$ENV{P} and s/^/#drop#/' $$s; \
		done; \
		rm "bb-tree/SOURCES/bb-patches/$$p"; \
	done
	mkdir bb-tree/SOURCES/bb-patches/fedora
	printf '\n' >> bb-tree/SOURCES/bb-patches/series
	for p in $(LOCAL_PATCHES); do \
		cp "patches/$$p" bb-tree/SOURCES/bb-patches/fedora/; \
		echo "fedora/$$p" >> bb-tree/SOURCES/bb-patches/series; \
	done
	(cd bb-tree/SOURCES && tar cJf bb-patches.tar.xz bb-patches)
	rm -rf bb-tree/SOURCES/bb-patches
	touch $@

$(langpack_base).tar.xz: $(locale_files) sources.sha512
	tar cJf $@ --transform='s,^langpacks,thunderbird-langpacks,' -C downloads $(addprefix langpacks/,$(addsuffix .xpi,$(locales)))

stage-2.stamp: stage-1.stamp $(langpack_base).tar.xz langpack-conv.sh
	./langpack-conv.sh "$(CURDIR)" "$(CURDIR)/$(SOURCE_ARCHIVE)" \
		$(THUNDERBIRD_PATCHES) $(BB_VERSION) "$(CURDIR)" "$(langpack_base)" "$(bb_langpack_base)"
	mv "$(bb_langpack_base).tar.xz" bb-tree/SOURCES/
	touch $@

stage-3.stamp: stage-2.stamp bb-prep-helper.sh
	grep -q '$(bb_mozconfig_marker)' $(PATCH_DIR)/mozconfig-Linux
	sed -n '/$(bb_mozconfig_marker)/,$$p' $(PATCH_DIR)/mozconfig-Linux > bb-tree/SOURCES/100-betterbird-mozconfig-extra
	cp $(THUNDERBIRD_PATCHES)/metadata/eu.betterbird.Betterbird.desktop bb-tree/SOURCES/
	cp $(THUNDERBIRD_PATCHES)/metadata/eu.betterbird.Betterbird.$(BB_VERSION).appdata.xml bb-tree/SOURCES/eu.betterbird.Betterbird.appdata.xml
	cp bb-tree/SOURCES/thunderbird-symbolic.svg bb-tree/SOURCES/eu.betterbird.Betterbird-symbolic.svg
	cp bb-prep-helper.sh bb-tree/SOURCES/
	touch $@

# Always start edits from the donor spec, so changed helpers cannot append a
# second changelog or retain substitutions from a previous conversion.
stage-4.stamp: stage-3.stamp spec-edit.sh description.txt
	cp src.unpack/thunderbird.spec $(bb_spec)
	./spec-edit.sh $(bb_spec) description.txt "$(bb_langpack_base)" "$(BB_RELEASE_TAG)" \
		"$(TB_VERSION)" "$(TB_SOURCE_URL)/source/$(SOURCE_ARCHIVE)"
	touch $@

stage-5.stamp: stage-4.stamp
	printf '\n%%changelog\n* %s %s - $(TB_VERSION)-2.$(BB_RELEASE_TAG)\n- Package Betterbird $(BB_TAG) with Fedora build integration\n- Register the Linux systray integration on all architectures\n' \
		"$$(date '+%a %b %d %Y')" "$(PACKAGER)" >> $(bb_spec)
	touch $@

# Exercise actual patch application without installing compiler dependencies.
prep: stage-5.stamp
	rpmbuild -bp --nodeps $(rpm_args) $(bb_spec)
verify: stage-5.stamp
	rpmspec -q --srpm --qf '%{NAME} %{VERSION}-%{RELEASE}\n' $(bb_spec)

clean:
	rm -f stage-*.stamp
	rm -rf src.unpack bb-tree tmp.*

.DELETE_ON_ERROR:
