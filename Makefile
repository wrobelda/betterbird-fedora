# GNU Make downloads and prepares the sources for betterbird.spec, then builds
# the source RPM. The spec pins every source version.
.DEFAULT_GOAL := srpm
.SHELLFLAGS := -ec
export LC_ALL := C

locales = cs de en-GB es-ES fr it ja nl pl pt-BR pt-PT ru sv-SE uk zh-CN

spec_field = $(shell rpmspec -P betterbird.spec 2>/dev/null | sed -n 's/^$(1):[[:space:]]*//p' | head -n 1)
version := $(call spec_field,Version)
tb_source_url := $(call spec_field,Source0)
bb_langpacks := $(call spec_field,Source1)
bb_archive_url := $(call spec_field,Source102)
ifeq ($(and $(version),$(tb_source_url),$(bb_langpacks),$(bb_archive_url)),)
$(error cannot read the version and source URLs from betterbird.spec)
endif

source_archive := $(notdir $(tb_source_url))
tb_candidate_url := $(tb_source_url:%/source/$(source_archive)=%)
langpacks := $(bb_langpacks:betterbird-%=thunderbird-%)
locale_files = $(addprefix downloads/langpacks/,$(addsuffix .xpi,$(locales)))
bb_archive := $(notdir $(bb_archive_url))
bb_series := $(firstword $(subst ., ,$(version)))
# The tagged Betterbird patch set with the additional fixes applied on top,
# for the language packs.
bb_tree = thunderbird-patches
bb_fixes := $(sort $(wildcard thunderbird-patches-*.patch))
cbindgen_sha512 := $(shell awk '$$2 == "cbindgen-vendor.tar.xz" {print $$1}' sources.sha512)
cbindgen_url = https://src.fedoraproject.org/repo/pkgs/rpms/thunderbird/cbindgen-vendor.tar.xz/sha512/$(cbindgen_sha512)/cbindgen-vendor.tar.xz

outdir ?= $(CURDIR)
rpm_args = --define "_topdir $(CURDIR)/bb-tree" \
	--define "_srcrpmdir $(abspath $(outdir))" \
	--define "_sourcedir $(CURDIR)"

.PHONY: all srpm sources fetch check-inputs check prep verify clean
all: srpm
srpm: sources
	mkdir -p "$(outdir)"
	rpmbuild -bs $(rpm_args) betterbird.spec
sources: $(source_archive) $(bb_archive) cbindgen-vendor.tar.xz $(bb_langpacks)
fetch: $(source_archive) $(bb_archive) cbindgen-vendor.tar.xz $(locale_files)

# Download source code and localization data only. Partial files are never
# accepted as completed downloads.
$(source_archive):
	curl --fail --location --retry 3 $(tb_source_url) -o $@.part
	mv $@.part $@
$(bb_archive):
	curl --fail --location --retry 3 $(bb_archive_url) -o $@.part
	mv $@.part $@
cbindgen-vendor.tar.xz:
	curl --fail --location --retry 3 $(cbindgen_url) -o $@.part
	mv $@.part $@
downloads/langpacks/%.xpi:
	mkdir -p $(@D)
	curl --fail --location --retry 3 $(tb_candidate_url)/linux-x86_64/xpi/$*.xpi -o $@.part
	mv $@.part $@

check-inputs: fetch
	sha512sum --check sources.sha512
check: check-inputs
	rpmspec -P betterbird.spec > /dev/null
	python3 -m unittest discover -s tests -v

$(bb_tree)/.prepared: $(bb_archive) $(bb_fixes) | check-inputs
	rm -rf $(bb_tree)
	mkdir $(bb_tree)
	tar -xzf $(bb_archive) -C $(bb_tree) --strip-components=1
	for p in $(bb_fixes); do patch -p1 --fuzz=0 -s -d $(bb_tree) -i "$(CURDIR)/$$p"; done
	touch $@

$(langpacks): $(locale_files) sources.sha512 | check-inputs
	tar cJf $@ --transform='s,^langpacks,thunderbird-langpacks,' -C downloads $(addprefix langpacks/,$(addsuffix .xpi,$(locales)))

$(bb_langpacks): $(langpacks) $(source_archive) $(bb_tree)/.prepared langpack-conv.sh
	./langpack-conv.sh "$(CURDIR)" "$(CURDIR)/$(source_archive)" \
		$(bb_tree) $(bb_series) "$(CURDIR)" "$(langpacks:.tar.xz=)" "$(bb_langpacks:.tar.xz=)"

# Exercise actual patch application without installing compiler dependencies.
prep: sources
	rpmbuild -bp --nodeps $(rpm_args) betterbird.spec
verify:
	rpmspec -q --srpm --qf '%{NAME} %{VERSION}-%{RELEASE}\n' betterbird.spec

clean:
	rm -rf bb-tree $(bb_tree) $(langpacks) $(bb_langpacks)

.DELETE_ON_ERROR:
