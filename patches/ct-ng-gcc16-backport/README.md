# GCC 16.1.0 crosstool-NG backport

GCC 16.1.0 is newer than the vendored crosstool-NG 1.25.0 and 1.28.0
releases. The Docker phase images register this package at image-build time
and copy it into the installed crosstool-NG package tree.

Only patches applicable to the Linux glibc targets are included:

- `0001-*` is crosstool-NG upstream's POSIX host-build fix.
- `0002-*` is required only for the CentOS 6 glibc 2.12 x86_64 sysroot.
- `0003-*` makes static libgcc interoperate with glibc cancellation through
  shared `libgcc_s`.
- `0004-*` fixes numeric timezone saves, external tzdata source detection, and
  updates the leap-second validity date from IERS Bulletin C 72.
- `0005-*` and `0006-*` backport the accepted PR 124852 timezone parser fixes.

The checksum file is copied from crosstool-NG upstream commit
`05d2040d3484a40ccb25edaac01d162cdfa43a32`.
