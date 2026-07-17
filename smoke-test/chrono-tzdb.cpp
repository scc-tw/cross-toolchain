#include <chrono>
#include <cstdio>
#include <cstring>
#include <stdexcept>

namespace {

const char* zoneinfo_override;

int check_embedded_data() {
    const auto& db = std::chrono::get_tzdb();
    (void) db.locate_zone("America/New_York");
    std::printf("TZDB version=%s embedded-fallback=ok\n", db.version.c_str());
    return 0;
}

int check_parser_regressions() {
    using namespace std::chrono;

    const auto& db = get_tzdb();

    const auto gaborone = db.locate_zone("Test/Gaborone")
                              ->get_info(sys_days{1943y / December / 15});
    if (gaborone.offset != 3h || gaborone.save != 60min) {
        std::fprintf(stderr,
                     "numeric SAVE was parsed incorrectly: "
                     "offset=%lld save=%lld\n",
                     static_cast<long long>(gaborone.offset.count()),
                     static_cast<long long>(gaborone.save.count()));
        return 1;
    }

    const auto simferopol = db.locate_zone("Test/LastSu")
                                ->get_info(sys_days{1997y / March / 15});
    const sys_seconds expected_end = sys_days{1997y / March / 30} + 1h;
    if (simferopol.end != expected_end) {
        std::fprintf(stderr,
                     "ON-format UNTIL was parsed incorrectly: "
                     "end=%lld expected=%lld\n",
                     static_cast<long long>(simferopol.end.time_since_epoch().count()),
                     static_cast<long long>(expected_end.time_since_epoch().count()));
        return 2;
    }

    std::printf("TZDB version=%s parser-regressions=ok\n", db.version.c_str());
    return 0;
}

int check_missing_leaps(const char* directory) {
    zoneinfo_override = directory;
    try {
        (void) std::chrono::reload_tzdb();
    } catch (const std::runtime_error&) {
        std::puts("TZDB external-missing-leapseconds=rejected");
        return 0;
    }

    std::fputs("external tzdata.zi without leapseconds was accepted\n", stderr);
    return 3;
}

} // namespace

namespace __gnu_cxx {

const char* zoneinfo_dir_override() {
    return zoneinfo_override;
}

} // namespace __gnu_cxx

int main(int argc, char** argv) {
    if (argc == 3 && std::strcmp(argv[1], "missing-leaps") == 0) {
        return check_missing_leaps(argv[2]);
    }
    if (argc == 3 && std::strcmp(argv[1], "historical") == 0) {
        zoneinfo_override = argv[2];
        return check_parser_regressions();
    }
    return argc == 1 ? check_embedded_data() : 64;
}
