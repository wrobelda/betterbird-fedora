# Betterbird converter for Debian

These scripts will programmatically convert a
[Debian](https://www.debian.org/) source package of the
[Thunderbird](https://packages.debian.org/unstable/thunderbird) graphical
e-mail client into an equivalent [Betterbird](https://www.betterbird.eu/)
one.

The resulting source package can be compiled into binary `.deb` files, just
like the original. These Betterbird `.deb` files can then be installed on a
system concurrently with the (regular) Thunderbird ones, as they should not
conflict.

(Note that regular Thunderbird and Betterbird cannot be *used*
concurrently, as they rely on the same user configuration.)


## Usage

1. Start with a Debian or Debian-derived system. Ensure that you have the
   necessary prerequisites installed:
   ```
   apt-get install devscripts git quilt rsync
   ```

2. Prepare a workspace for the conversion. You can use either the directory
   of this (Git) tree itself, or an empty directory if you copy/symlink in
   the `Makefile` and set the `DEBIAN_CONVERT` variable therein to the
   appropriate location. You'll need at least 8 GB of free disk space.

3. Download a `thunderbird` source package from Debian. If you are on a
   Debian system, running `apt-get source thunderbird` should suffice.
   Otherwise, visit the Debian [source package
   page](https://packages.debian.org/source/unstable/thunderbird), and
   download the required files using the links near the bottom.

4. Clone the
   [Betterbird/thunderbird-patches](https://github.com/Betterbird/thunderbird-patches.git)
   Git repo, and checkout the Git tag that matches the base version of
   Thunderbird that you downloaded from Debian. (It is important to use a
   revision of the thunderbird-patches tree that matches the Thunderbird
   version.)

   For example, if the source version is `140.5.0esr`, then you could
   get an appropriate set of patches with `git checkout 140.5.1esr-bb14`.
   (Use `git tag --list` to see the full list of tags.)

   Note that Debian Thunderbird package versions can also have a numeric
   suffix like `-1`, but it has nothing to do with the numbering of
   Betterbird tags. Only the part up to the `esr` suffix is shared between
   those two contexts.

5. If the source package is not already unpacked, then do so by running
   `dpkg-source -x thunderbird_$VERSION.dsc`.

6. The conversion process is driven primarily by the `Makefile`. Edit the
   variables in the first section of the file to appropriate values.

7. Run `make source-package`, and wait a few minutes for the process to
   complete.

8. If the process is successful, then you'll see a new set of
   Betterbird source-package files (`.dsc`, `.debian.tar.xz`,
   `.orig.tar.xz`, etc.) in the workspace. These can be built into binary
   `.deb` files using `dpkg-buildpackage(1)`.

9. Run `make clean` to clean up intermediate files in the workspace.


## Pitfalls

A few things can go wrong in the conversion process:

* **Betterbird patches fail to apply.** This is usually due to an
  incompatibility with the Debian patches, either because the same
  Thunderbird file is being modified in different ways, or Betterbird
  adopted one of Debian's patches (or vice versa). It can often be resolved
  by adding one or more patches to `PATCH_DROP_LIST`. (Determining which
  patch(es) should be added is left as an exercise for the reader.)

* **`PATCH_DROP_LIST` contains patches not in the patch series.** Typically
  the result of either Debian Thunderbird or Betterbird dropping a patch
  that is still listed in the variable. Just remove it.

* **Not enough disk space.** The Thunderbird source tree is quite large!
