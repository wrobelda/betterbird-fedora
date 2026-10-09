#!/bin/bash
# spec-edit.sh
#
# Rewrite the Fedora Thunderbird spec as a Betterbird spec by search/replace
# and a few structural splice-ins. It is invoked by the Makefile's edit-spec
# recipe.
#
#   spec-edit.sh <spec> <description> <langpacks> <release-tag>
#                <rpm-version> <source-url>
# Always pass an unmodified Fedora spec.

set -eu

spec=$1
desc_file=$2
bb_lpb=$3
bb_tag=$4
rpm_version=$5
source_url=$6

test -f "$spec"
test -f "$desc_file"
# Refuse a spec layout that cannot run the Betterbird preparation hook.
grep -q '^%setup -q' "$spec"
grep -q '^%{__rm} -f .mozconfig$' "$spec"
grep -q '^%{__cp} %{SOURCE10} .mozconfig$' "$spec"

BB_DESC=$(cat "$desc_file")
export BB_DESC

sub()  { perl -pi -e "$1" "$spec"; }
sub77(){ perl -0777 -i -pe "$1" "$spec"; }

# --- top-level metadata -------------------------------------------------------
sub 's/^Name:\s+\K.*/betterbird/'
# Replace only the *main* (first) Summary; subpackage summaries are rebranded
# by the blanket pass below.
sub77 's/^Summary:\s+\K.*/Betterbird graphical mail and newsgroup client/m'
sub 's/^URL:\s+\K.*/https:\/\/www.betterbird.eu\//'
sub "s/^Version:\\s+\\K.*/$rpm_version/"
sub "s/^Release:\\s+\\K.*/1.$bb_tag%{?dist}/"
# The generated release is explicit and does not use Fedora's autorelease.
sub77 's/^## START: Set by rpmautospec\n.*?^## END: Set by rpmautospec\n\n//ms'

# --- Source filename rewrites -------------------------------------------------
sub "s/^Source1:\\s+\\K.*/$bb_lpb.tar.xz/"
sub 's/^Source12:\s+\K.*/betterbird-redhat-default-prefs.js/'
sub 's/^Source25:\s+\K.*/eu.betterbird.Betterbird-symbolic.svg/'
sub 's/^Source33:\s+\K.*/eu.betterbird.Betterbird.desktop/'
sub 's/^Source34:\s+\K.*/eu.betterbird.Betterbird.appdata.xml/'

# For the prep helper, mozconfig-extra, and BB-patches tarball added by the
# converter, declare them as Source100/101/102 if not already present.
if ! grep -q '^Source100:' "$spec"; then
perl -0777 -i -pe 's/(^Source0:.*\n)/"Source100:     bb-prep-helper.sh\n" . $1/me' "$spec"
fi
if ! grep -q '^Source101:' "$spec"; then
perl -0777 -i -pe 's/(^Source100:.*\n)/$1 . "Source101:     100-betterbird-mozconfig-extra\n"/me' "$spec"
fi
if ! grep -q '^Source102:' "$spec"; then
perl -0777 -i -pe 's/(^Source101:.*\n)/$1 . "Source102:     bb-patches.tar.xz\n"/me' "$spec"
fi

# --- branding: Betterbird branding, not official branding --------------------
sub 's/^%define official_branding\s+\K1/0/'
sub 's/^%define enable_mozilla_crashreporter\s+\K1/0/'
# Append the Betterbird-specific mozconfig directives right after the existing
# `cp %{SOURCE10} .mozconfig` line in %prep (idempotent).
if ! grep -q 'cat %{SOURCE101}' "$spec"; then
sub77 's/(%\{__cp\}\s+%\{SOURCE10\}\s+\.mozconfig\n)/$1 . "cat %{SOURCE101} >> .mozconfig\n"/e'
fi

# --- main %description: replace the first (main) %description body, up to the
#     next %section, with the Betterbird description text. -------------------
sub77 's/(^%description\n).*?(?=^%|\Z)/$1 . $ENV{BB_DESC} . "\n"/mse'

# --- strip the Fedora %changelog (regenerated later) -------------------------
sub77 's/^%changelog\n.*//ms'

# --- net.thunderbird.Thunderbird rDNS -> eu.betterbird.Betterbird --------------
sub 's/net\.thunderbird\.Thunderbird/eu.betterbird.Betterbird/g'

# --- blanket package-name replacement ----------------------------------------
sub 's/\bthunderbird\b/betterbird/g'
sub 's/\bThunderbird\b/Betterbird/g if /^Summary:/'

# --- exceptions: keep the upstream TB source URL and mozconfig filenames -----
sub 's{archive\.mozilla\.org/pub/betterbird/releases}{archive.mozilla.org/pub/thunderbird/releases}g'
sub 's/^(Source10:\s+)betterbird-mozconfig\b/$1thunderbird-mozconfig/'
sub 's/^(Source11:\s+)betterbird-mozconfig-branded\b/$1thunderbird-mozconfig-branded/'
# Keep the original archive name and its exact release-candidate URL.
BB_SOURCE_URL=$source_url
export BB_SOURCE_URL
sub 's{^Source0:\s+\K.*}{$ENV{BB_SOURCE_URL}}'

# --- langpack extension IDs: @betterbird.eu (not @betterbird.mozilla.org) -----
sub 's/\@betterbird\.mozilla\.org/\@betterbird.eu/g'
sub 's/thunderbird\@mozilla\.org/betterbird\@betterbird.eu/g'

# The pinned ESR package manifest ships librnp without the standalone RNP tools.
sub 's{^%\{mozappdir\}/(?:rnp-cli|rnpkeys)\s*$}{}'

# --- %setup: the upstream source tarball extracts to thunderbird-%{version}/,
#     but %setup derives the dir from Name+Version (= betterbird-%{version}).
#     This must run AFTER the blanket rename above, which turns
#     `thunderbird-%{version}` into `betterbird-%{version}` in %setup; we
#     restore the correct directory name here. -------------------------------
sub 's/^%setup\s+-q\s+-n\s+betterbird-%\{version\}/%setup -q -n thunderbird-%{version}/'
sub 's/^%setup\s+-q\b(?! -n)/%setup -q -n thunderbird-%{version}/'

# --- icon filenames: Icon=eu.betterbird.Betterbird expects
#     eu.betterbird.Betterbird.png / ...-symbolic.svg --------------------------
sub 's{/apps/betterbird\.png}{/apps/eu.betterbird.Betterbird.png}g'
sub 's/\bbetterbird-symbolic\.svg\b/eu.betterbird.Betterbird-symbolic.svg/g'

# --- WM remotename -----------------------------------------------------------
sub 's/(export\s+MOZ_APP_REMOTINGNAME=)[^'"'"'\s]+/$1eu.betterbird.Betterbird/g'

# --- BuildRequires for the BB patch application (git-core) and unzip ----------
if ! grep -q '^BuildRequires:.*git-core' "$spec"; then
sub77 's{(\nBuildRequires:[^\n]*\n)}{$1 . "BuildRequires:  git-core\nBuildRequires:  /usr/bin/unzip\n"}me'
fi

# --- %prep: insert the BB-patch apply hook. It runs *after* Fedora's own %patch
#     lines, so Betterbird patches layer on top of the Fedora build patches
#     (matching how the Debian converter orders distro-then-Betterbird). We
#     anchor on the "%{__rm} -f .mozconfig" line that begins the mozconfig
#     setup, which follows all the %patch directives. -------------------------
if ! grep -q '.bb-prep.sh' "$spec"; then
sub77 's/(^%\{__rm\} -f \.mozconfig\n)/"# Apply Betterbird patches after the Fedora patches.\n" . "tar xf %{SOURCE102}\n%{__cp} %{SOURCE100} .bb-prep.sh\n%{__chmod} 755 .bb-prep.sh\n.\/.bb-prep.sh bb-patches\n\n" . $1/me'
fi

echo "=== edit-spec key fields ==="
grep -nE '^(Name|Summary|URL|Release|Source1|Source10|Source11|Source12|Source25|Source33|Source34|Source100|Source101|Source102):' "$spec" || true

# end spec-edit.sh
