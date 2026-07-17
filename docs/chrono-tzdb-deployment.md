# GCC 16 C++20 timezone deployment

## Current contract

The GCC 16 defconfigs do not pass `--with-libstdcxx-zoneinfo`, so libstdc++
uses the GNU/Linux default:

```text
/usr/share/zoneinfo,static
```

At runtime it reads `/usr/share/zoneinfo/tzdata.zi` when that file exists and
otherwise uses the tzdata embedded in libstdc++. GCC 16.1.0 embeds IANA
tzdata 2025c. Individual compiled TZif files and `zone.tab` are not inputs to
the C++20 tzdb parser. The separate `/usr/share/zoneinfo/leapseconds` file is
used for leap-second updates.

This setting is intentional for the relocatable toolchain archives. An
absolute directory below `/opt/x-tools` would stop working when an archive is
extracted under another prefix. Host tzdata can therefore change timezone
answers without relinking, while the embedded database preserves operation on
old systems that do not provide `tzdata.zi`.

`-static-libstdc++` does not change this precedence. A statically linked
libstdc++ still reads the runtime host's `tzdata.zi` first.

## Product-pinned data

Applications that require reproducible timezone rules should ship a reviewed
`tzdata.zi` and `leapseconds` pair and provide a strong definition of the weak
libstdc++ hook:

```cpp
namespace __gnu_cxx {
const char* zoneinfo_dir_override() {
    return "/opt/vendor/product/share/zoneinfo";
}
}
```

The directory is application policy, not a cross-toolchain install path. Both
files must be updated and tested as one release unit. Missing or malformed
external leap data is treated as an error by this toolchain's GCC patch.

If every consumer later adopts one canonical product prefix, the three GCC 16
defconfigs can instead use:

```text
--with-libstdcxx-zoneinfo=/opt/vendor/product/share/zoneinfo,static
```

Keep `,static` so relocated archives and incomplete deployment roots retain a
known fallback.

## Known GCC 16 limits

The local backports cover numeric fixed SAVE values and ON-form Zone UNTIL
days. Later parser work for PR 124853, PR 124854, and the remaining PR 116110
cases is not backported because the fixes are incomplete or depend on broader
parser changes. Applications needing exact historical transitions should run
their own representative-zone differential tests when tzdata or GCC changes.

`std::chrono::current_zone()` does not interpret the `TZ` environment variable.
It derives a name from system timezone configuration and can fall back to
`Etc/UTC`; applications that honor `TZ` should resolve that policy themselves.
