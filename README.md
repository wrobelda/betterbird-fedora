# Betterbird for Fedora

Fedora packaging for [Betterbird](https://www.betterbird.eu/), an enhanced
version of Thunderbird. This project combines Fedora Thunderbird packaging
with Betterbird source changes and branding.

This project adapts the
[betterbird-debian](https://salsa.debian.org/iskunk/betterbird-debian)
conversion scripts to Fedora’s RPM packaging.
See [Betterbird issue #544](https://github.com/Betterbird/thunderbird-patches/issues/544)
for the original Debian packaging discussion.

## Installation

See the [COPR repository](https://copr.fedorainfracloud.org/coprs/wrobelda/betterbird/)
for installation instructions, available builds, and supported Fedora releases.

If you also use Thunderbird, create a separate profile for Betterbird.
Do not open the same profile in both programs at once.

## Building

The Makefile downloads the required sources and produces a source RPM,
which contains the source code and RPM build instructions.
Run these commands from a checkout on Fedora with the RPM packaging tools installed:

```console
make check
make srpm
```

`make check` checks source integrity and runs the conversion tests.
`make srpm` writes the source RPM to the checkout directory.
Build the resulting source RPM with COPR or Mock to produce installable RPMs.

`make clean` removes the generated build tree and conversion records.
It retains downloaded sources, the patches checkout, and completed source RPMs.
