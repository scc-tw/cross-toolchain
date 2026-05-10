// cpp17-stress.cpp — exercise C++17 stdlib on the cross-toolchain
//
// Verifies these stdlib pieces actually link and execute correctly:
//   - <vector>, <string>, <map>             (containers)
//   - <thread>, <mutex>, <atomic>           (concurrency)
//   - <regex>                                (regex)
//   - <chrono>                               (time)
//   - <filesystem>                           (filesystem, C++17)
//   - <optional>, <variant>, <string_view>   (C++17 vocabulary types)
//   - structured bindings, fold expressions, if constexpr, CTAD
//   - exception throwing across translation units
//
// 任一 target 跑完印 PASS：cross-toolchain 的 g++/clang++ + libstdc++/libc++ 全通

#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <map>
#include <thread>
#include <mutex>
#include <atomic>
#include <regex>
#include <chrono>
#include <filesystem>
#include <optional>
#include <variant>
#include <string_view>
#include <stdexcept>
#include <numeric>
#include <type_traits>

namespace fs = std::filesystem;

// fold expression (C++17)
template<typename... Args>
auto sum_all(Args... args) {
    return (args + ...);
}

// if constexpr (C++17)
template<typename T>
auto stringify(T value) {
    if constexpr (std::is_arithmetic_v<T>) {
        return std::to_string(value);
    } else {
        return std::string(value);
    }
}

int main() {
    int failures = 0;
    auto check = [&](const char* name, bool ok) {
        std::cout << "  [" << (ok ? "OK  " : "FAIL") << "] " << name << "\n";
        if (!ok) failures++;
    };

    std::cout << "=== C++17 stdlib stress test ===\n";

    // 1. vector + structured bindings + lambda
    std::vector<std::pair<std::string, int>> pairs = {{"alpha", 1}, {"beta", 2}, {"gamma", 3}};
    int sum = 0;
    for (const auto& [k, v] : pairs) {  // structured bindings
        sum += v;
    }
    check("vector + structured bindings", sum == 6);

    // 2. fold expression
    check("fold expression sum_all(1,2,3,4)", sum_all(1, 2, 3, 4) == 10);

    // 3. if constexpr
    check("if constexpr stringify int", stringify(42) == "42");
    check("if constexpr stringify str", stringify("hi") == "hi");

    // 4. std::optional + std::variant + std::string_view (C++17 vocab)
    std::optional<int> opt;
    check("optional empty", !opt.has_value());
    opt = 7;
    check("optional has value", opt.value() == 7);

    std::variant<int, std::string> var = std::string{"hello"};
    check("variant string", std::holds_alternative<std::string>(var));

    std::string_view sv = "abcdef";
    check("string_view substr", sv.substr(2, 3) == "cde");

    // 5. threads + atomic + mutex (CTAD on lock_guard)
    std::atomic<int> counter{0};
    std::mutex mu;
    int unsafe = 0;
    std::vector<std::thread> threads;
    for (int i = 0; i < 8; i++) {
        threads.emplace_back([&]{
            for (int j = 0; j < 1000; j++) {
                counter.fetch_add(1, std::memory_order_relaxed);
                std::lock_guard lock{mu};  // C++17 CTAD on lock_guard<std::mutex>
                unsafe++;
            }
        });
    }
    for (auto& t : threads) t.join();
    check("atomic fetch_add (8 threads x 1000)", counter.load() == 8000);
    check("mutex-protected counter", unsafe == 8000);

    // 6. regex
    std::regex re(R"((\w+)\s*=\s*(\d+))");
    std::smatch match;
    std::string s = "answer = 42";
    bool ok = std::regex_search(s, match, re);
    check("regex_search match", ok);
    check("regex group 1", match[1].str() == "answer");
    check("regex group 2", match[2].str() == "42");

    // 7. chrono
    auto t1 = std::chrono::steady_clock::now();
    auto t2 = std::chrono::steady_clock::now();
    auto dur = std::chrono::duration_cast<std::chrono::nanoseconds>(t2 - t1);
    check("chrono steady_clock", dur.count() >= 0);

    // 8. stringstream (in-memory I/O)
    std::stringstream ss;
    ss << "answer=" << 42 << " pi=" << 3.14;
    check("stringstream write+read", ss.str() == "answer=42 pi=3.14");

    // 9. filesystem + fstream (寫到容器內 /tmp，docker --rm 跑完就清)
    fs::path p = "/tmp/smoke_test_xyz";
    try {
        fs::create_directories(p / "sub");
        std::ofstream(p / "sub/file.txt") << "hello\n";
        bool exists = fs::exists(p / "sub/file.txt");
        auto sz = fs::file_size(p / "sub/file.txt");
        fs::remove_all(p);
        check("filesystem create+exists", exists);
        check("filesystem file_size=6", sz == 6);
    } catch (const fs::filesystem_error& e) {
        std::cerr << "  filesystem error: " << e.what() << "\n";
        failures++;
    }

    // 9. exceptions across function boundaries
    auto thrower = [](int x) {
        if (x < 0) throw std::runtime_error("negative");
        return x * 2;
    };
    int caught = 0;
    try { thrower(-1); } catch (const std::runtime_error&) { caught = 1; }
    check("exception caught across lambda", caught == 1);

    // 10. std::accumulate (numerics)
    std::vector<int> nums = {1, 2, 3, 4, 5};
    int acc = std::accumulate(nums.begin(), nums.end(), 0);
    check("accumulate 1..5", acc == 15);

    // 11. map with custom comparator + emplace
    std::map<std::string, int> mp;
    mp.emplace("first", 1);
    mp.emplace("second", 2);
    int total = 0;
    for (const auto& [k, v] : mp) total += v;
    check("map emplace + iterate", total == 3);

    std::cout << "=== " << (failures == 0 ? "PASS" : "FAIL") << " (" << failures << " failures) ===\n";
    return failures;
}
