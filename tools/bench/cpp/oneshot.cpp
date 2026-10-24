// One cold measurement of the official Kaitai Struct C++ runtime, as
// tools/bench/main.odin is of zelbyn (doc/development.md, Benchmark). build.py
// compiles it with the parser that the official compiler generates from a
// .ksy schema; bench.py runs it in a fresh process for every measurement.
//
//     oneshot_cpp <file>
//
// Reads the file into a std::string, then builds a kaitai::kstream on it
// and parses it: that is the decode. Prints one line of name=value pairs:
// read_us, decode_us, and faults, the page faults taken during the decode
// (-1 where getrusage is not available). The parsed object is never freed,
// as zelbyn's tree is not.
#include KS_HEADER

#include <chrono>
#include <cstdio>
#include <exception>
#include <fstream>
#include <string>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/resource.h>
static long page_faults() {
    rusage r;
    if (getrusage(RUSAGE_SELF, &r) != 0) return -1;
    return r.ru_minflt + r.ru_majflt;
}
#else
static long page_faults() { return -1; }
#endif

typedef std::chrono::steady_clock Clock;

static double us(Clock::time_point a, Clock::time_point b) {
    return std::chrono::duration<double, std::micro>(b - a).count();
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: oneshot_cpp <file>\n");
        return 2;
    }

    Clock::time_point t0 = Clock::now();
    std::ifstream f(argv[1], std::ios::binary | std::ios::ate);
    if (!f) {
        std::fprintf(stderr, "cannot read %s\n", argv[1]);
        return 1;
    }
    std::string data(static_cast<size_t>(f.tellg()), '\0');
    f.seekg(0);
    if (!f.read(&data[0], static_cast<std::streamsize>(data.size()))) {
        std::fprintf(stderr, "cannot read %s\n", argv[1]);
        return 1;
    }
    Clock::time_point t1 = Clock::now();

    long faults = page_faults();
    try {
        kaitai::kstream* ks = new kaitai::kstream(data);
        new KS_ROOT(ks);
    } catch (const std::exception& e) {
        std::fprintf(stderr, "%s: %s\n", argv[1], e.what());
        return 1;
    }
    Clock::time_point t2 = Clock::now();
    if (faults >= 0) faults = page_faults() - faults;

    std::printf("read_us=%.1f decode_us=%.1f faults=%ld\n", us(t0, t1), us(t1, t2), faults);
    return 0;
}
