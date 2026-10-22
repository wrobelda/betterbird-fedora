#!/bin/bash
# langpack-conv.sh
#
# Convert the Fedora Thunderbird langpacks tarball into an equivalent
# Betterbird one.
#
# The Fedora "thunderbird-langpacks-<version>-<date>.tar.xz" archive contains
# a directory of Mozilla-released language-pack .xpi files, each carrying the
# extension ID "langpack-<locale>@thunderbird.mozilla.org". Betterbird uses
# "langpack-<locale>@betterbird.eu" instead, adds an update URL, ships a
# brand-specific localization for each supported locale, and only supports a
# subset of the available locales. This script performs all of those
# transformations and repackages the result.
#
# Note: GNU patch, used by quilt(1) or the Debian toolchain, does not support
# git-style copy/rename/binary diffs, and the langpack branding patches use
# copy directives. Here we therefore use "git apply", which handles them.
# That mirrors how the Betterbird build itself applies these patches.

set -eu

# --- arguments ---------------------------------------------------------------
#   $1  work/ directory (cwd), holds tmp dirs and the output tarball
#   $2  SOURCE_TARBALL     : Thunderbird upstream source tarball
#                            (thunderbird-<ver>.source.tar.xz), only used to
#                            extract the en-US brand files; not fully unpacked
#   $3  THUNDERBIRD_PATCHES: Betterbird/thunderbird-patches tree (with the
#                            <BB_VERSION>/ subdir)
#   $4  BB_VERSION          : patches-tree version subdir, e.g. 153
#   $5  SRC_RPM_DIR         : directory holding the original langpacks tarball
#   $6  LANG_PACK_BASE       : tarball basename, e.g. thunderbird-langpacks-152.0-20260618
#   $7  BB_LANG_PACK_BASE    : output tarball basename, e.g. betterbird-langpacks-152.0-20260618
# ----------------------------------------------------------------------------

WORK=$1; SOURCE_TARBALL=$2; THUNDERBIRD_PATCHES=$3; BB_VERSION=$4
SRC_RPM_DIR=$5; LANG_PACK_BASE=$6; BB_LANG_PACK_BASE=$7

# Normalize inputs to absolute paths so directory changes below don't
# invalidate them.
case "$WORK"             in /*) ;; *) WORK=$PWD/$WORK             ;; esac
case "$SOURCE_TARBALL"   in /*) ;; *) SOURCE_TARBALL=$PWD/$SOURCE_TARBALL   ;; esac
case "$THUNDERBIRD_PATCHES" in /*) ;; *) THUNDERBIRD_PATCHES=$PWD/$THUNDERBIRD_PATCHES ;; esac
case "$SRC_RPM_DIR"      in /*) ;; *) SRC_RPM_DIR=$PWD/$SRC_RPM_DIR      ;; esac

if [ -z "$WORK" ] || [ -z "$SOURCE_TARBALL" ] || [ -z "$THUNDERBIRD_PATCHES" ] || [ -z "$BB_VERSION" ] || [ -z "$SRC_RPM_DIR" ] || [ -z "$LANG_PACK_BASE" ] || [ -z "$BB_LANG_PACK_BASE" ]; then
	echo "usage: $0 <work> <source-tarball> <tb-patches> <bb-version> <src-rpm-dir> <langpack-base> <bb-langpack-base>" >&2
	exit 1
fi
test -f "$SOURCE_TARBALL"

ORIG_TARBALL="$SRC_RPM_DIR/$LANG_PACK_BASE.tar.xz"
OUT_TARBALL="$WORK/$BB_LANG_PACK_BASE.tar.xz"

PATCH_DIR=$THUNDERBIRD_PATCHES/$BB_VERSION
SCRIPTS_DIR=$PATCH_DIR/scripts
bb_langpack_update_url='https://www.betterbird.eu/downloads/LanguagePacks/updates.json'

test -d "$PATCH_DIR/branding"
test -d "$SCRIPTS_DIR"

ORIG_DIR=$WORK/lp-orig
WRK_DIR=$WORK/lp-wrk

cd "$WORK"

# Extract the langpacks tarball. The archive contains a top-level directory
# (thunderbird-langpacks/) holding <locale>.xpi files; normalize to
# $ORIG_DIR/distro/<locale>.xpi
rm -rf "$ORIG_DIR" "$WRK_DIR"
mkdir -p "$ORIG_DIR"
( cd "$ORIG_DIR" && tar xJf "$ORIG_TARBALL" )
found_dir=
for d in "$ORIG_DIR/thunderbird-langpacks" "$ORIG_DIR"/*; do
	[ -d "$d" ] || continue
	# A directory that actually contains .xpi files is the langpack root.
	if ls "$d"/*.xpi >/dev/null 2>&1; then found_dir=$d; break; fi
done
if [ -z "$found_dir" ]; then
	echo "error: no .xpi files found in $ORIG_TARBALL" >&2
	exit 1
fi
rm -rf "$ORIG_DIR/distro"
mv "$found_dir" "$ORIG_DIR/distro"

# Prepare Betterbird en-US brand files. We extract only the en-US brand.*
# files from the (huge) Thunderbird source tarball into a minimal tree
# mail/branding/thunderbird/locales/en-US/, then apply the Betterbird branding
# patches 01 and 02 (filtered to brand.* files) which copy them to
# mail/branding/betterbird/locales/en-US/ and rewrite the brand strings.
BB_BRAND=$WORK/bb-brand
rm -rf "$BB_BRAND"
mkdir -p "$BB_BRAND"
# Strip the top-level "<ver>/comm/" prefix so the tree begins at mail/.
tar xJf "$SOURCE_TARBALL" -C "$BB_BRAND" --strip-components=2 \
	--wildcards '*/comm/mail/branding/thunderbird/locales/en-US/brand.*'

test -f "$BB_BRAND/mail/branding/thunderbird/locales/en-US/brand.dtd"
test -f "$BB_BRAND/mail/branding/thunderbird/locales/en-US/brand.properties"
test -f "$BB_BRAND/mail/branding/thunderbird/locales/en-US/brand.ftl"

( cd "$BB_BRAND" \
  && cat "$PATCH_DIR/branding/01-branding.patch" \
         "$PATCH_DIR/branding/02-branding.patch" \
  | GIT_DIR=/dev/null git apply --include='**/brand.*' - ) || {
	echo "error: failed to apply Betterbird branding patches to en-US brand files" >&2
	exit 1
}

BB_BRAND_ENUS="$BB_BRAND/mail/branding/betterbird/locales/en-US"
test -f "$BB_BRAND_ENUS/brand.dtd"
test -f "$BB_BRAND_ENUS/brand.properties"
test -f "$BB_BRAND_ENUS/brand.ftl"

# Iterate the locale .xpi files. A locale is supported by Betterbird iff a
# matching per-locale script exists. Unsupported locales are dropped; supported
# ones are re-zipped with the Betterbird extension ID, an update URL, the
# Betterbird en-US brand files, and the locale-specific patches from the BB
# scripts directory.
OUT_DIR=$WRK_DIR/distro
mkdir -p "$OUT_DIR"
supported_count=0
dropped_count=0

for xpi_path in "$ORIG_DIR"/distro/*.xpi; do
	locale=$(basename "$xpi_path" .xpi)
	locale_dir=$SCRIPTS_DIR/$locale.sh

	if [ ! -f "$locale_dir" ]; then
		dropped_count=$((dropped_count+1))
		echo "  dropping unsupported locale \"$locale\""
		continue
	fi

	supported_count=$((supported_count+1))
	echo "converting locale \"$locale\""

	stage=$WORK/lp-stage-$locale
	rm -rf "$stage"
	mkdir "$stage"
	( cd "$stage" && unzip -qq "$xpi_path" )
	# Rebranding changes signed files, so the original signature is invalid.
	rm -rf "$stage/META-INF"

	# Rewrite the langpack extension ID, rebrand the description, and add the
	# Betterbird langpack update URL.
	manifest=$stage/manifest.json
	export BB_LPU="$bb_langpack_update_url"
	perl -0777 -i -pe '
		s/"(langpack-\S{1,8})\@thunderbird\.mozilla\.org"/"$1\@betterbird.eu"/g;
		s/\bThunderbird Language Pack/Betterbird Language Pack/g;
		s/"Thunderbird \(Language Pack\)"/"Betterbird (Language Pack)"/g;
		s/^(\s+)("id":\s*"[^"]*langpack[^"]*",\s*\n)/$1$2$1"update_url": "$ENV{BB_LPU}",\n/m;
	' "$manifest"
	unset BB_LPU

	# Replace the locale's brand files with the Betterbird en-US brand files.
	# (All shipped Betterbird langpacks share the same brand strings.)
	for brand_file in $(cd "$stage" && find . -type f -name 'brand.*'); do
		bn=$(basename "$brand_file")
		cp "$BB_BRAND_ENUS/$bn" "$stage/$brand_file" || exit 1
	done

	# Apply the locale-specific script (operating relative to its root).
	( cd "$stage" && sh -e "$locale_dir" )

	# Fedora derives the extension ID from the XPI filename. Keep the locale
	# filename and store the Betterbird extension ID in manifest.json.
	( cd "$stage" && zip -qq -r9mX "$OUT_DIR/$locale.xpi" . )
	rm -rf "$stage"
done

if [ "$supported_count" -eq 0 ]; then
	echo "error: no supported Betterbird locales were converted" >&2
	exit 1
fi

# Repackage as a Betterbird langpacks tarball. The SRPM tarball *filename* is
# betterbird-langpacks-<v>-<date>.tar.xz, but the spec's %install expects the
# archive to extract to a top-level "betterbird-langpacks/" directory, so we
# name the directory accordingly.
rm -rf "$WRK_DIR/betterbird-langpacks"
mv "$OUT_DIR" "$WRK_DIR/betterbird-langpacks"
( cd "$WRK_DIR" && tar cJf "$OUT_TARBALL" betterbird-langpacks )

# Clean up intermediates.
rm -rf "$ORIG_DIR" "$WRK_DIR" "$BB_BRAND"

echo "  Supported locales: $supported_count"
echo "  Dropped locales:    $dropped_count"
echo "wrote $OUT_TARBALL"

# end langpack-conv.sh
