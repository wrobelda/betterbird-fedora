#!/bin/bash
# patch-conv.sh
#
# Script to convert the Betterbird patches into a form usable in a
# quilt-format Debian source package. Notably, Git binary diffs are
# not supported, so we "extract" them into their resulting files,
# and replace them with patch directives to copy said files into the
# correct locations.
#

bb_debian=$1
bb_series=$2

set -eu

convert_patch_series()
{
	rm -f tmp.binary-files.patch

	cat >> $bb_debian/patches/series << END

##
## Betterbird patches
##

END

	local line patch misc

	while read line
	do
		case "$line" in
			'#'* | '')
			echo "$line" >> $bb_debian/patches/series
			continue
			;;
		esac

		read patch misc <<< $line

		local patch_path=$bb_debian/patches/betterbird/$patch
		if [ ! -f $patch_path ]
		then
			# Probably in PATCH_NUKE_LIST
			echo "Skipping patch file betterbird/$patch"
			continue
		fi

		if grep -Fqx 'GIT binary patch' $patch_path
		then
			local bdiff_sed='/^diff --git .*\.(bmp|ico|png)$/,/^$/'

			sed -r "$bdiff_sed d" $patch_path > tmp.patch

			if grep -Fx -B3 'GIT binary patch' tmp.patch
			then
				# Add to bdiff_sed above
				echo "error: unhandled binary file type (see above): $patch"
				exit 1
			fi

			sed -nr "$bdiff_sed p" $patch_path >> tmp.binary-files.patch

			if grep -q '^+++ b/' tmp.patch
			then
				# Patch still contains some text edits
				echo '==== Note: Git binary diffs have been removed from this patch ====' >> tmp.patch
				cat tmp.patch > $patch_path
				echo "betterbird/$line" >> $bb_debian/patches/series
				echo "Edited out Git binary diffs from betterbird/$patch"
			else
				rm $patch_path
				echo "Removed all-binary betterbird/$patch"
			fi

			rm tmp.patch
		else
			# Normal text patch
			echo "betterbird/$line" >> $bb_debian/patches/series
		fi
	done < $bb_series
}

extract_binary_files()
{
	rm -rf $bb_debian/bb-resources
	test -f tmp.binary-files.patch || return 0
	mkdir $bb_debian/bb-resources

	# Note: The GIT_DIR=/dev/null bit is needed in case we are inside
	# a Git repo, because then "git apply" will refuse to create files
	# that it thinks are "outside" the repo.

	local bin_patch_file=$PWD/tmp.binary-files.patch
	(cd $bb_debian/bb-resources && GIT_DIR=/dev/null git apply -v $bin_patch_file)

	if ! find $bb_debian/bb-resources -type f | grep -q .
	then
		echo 'error: failed to extract any binary files!'
		exit 1
	fi

	cat > $bb_debian/bb-resources/README << END
This subdirectory contains files extracted from binary patches in the
Betterbird/thunderbird-patches Git repository.
END

	local bin_file
	local copy_patch=betterbird/debian-copy-resources.patch

	grep '^diff --git ' tmp.binary-files.patch \
	| awk '{ print $4 }' \
	| sed 's!^b/!!' \
	| while read bin_file
	do
		cat << END
diff --git a/debian/bb-resources/$bin_file b/$bin_file
copy from debian/bb-resources/$bin_file
copy to $bin_file
END
	done \
	> $bb_debian/patches/$copy_patch

	# dpkg-source(1) will show a "diff ... doesn't contain any patch"
	# warning for this patch file; it is harmless.

	(echo; echo $copy_patch) >> $bb_debian/patches/series

	echo "Created $copy_patch"
	rm tmp.binary-files.patch
}

################################################################

convert_patch_series

extract_binary_files

# end patch-conv.sh
