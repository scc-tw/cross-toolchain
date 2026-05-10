// leveldb-app.cc — minimal C++ program using libleveldb.a
//
// Verifies our cross-toolchain can build + link a real C++ program against
// a non-trivial third-party C++ library (leveldb 28k LOC).
//
// Test: open a leveldb in container's /tmp, write+read a key, list, close, delete dir.
// Container --rm 自動清，沒 host 殘留。

#include <iostream>
#include <string>
#include <filesystem>
#include "leveldb/db.h"
#include "leveldb/options.h"

namespace fs = std::filesystem;

int main() {
    fs::path dbpath = "/tmp/smoke-leveldb-test";
    fs::remove_all(dbpath);  // 確保 clean state

    leveldb::Options opts;
    opts.create_if_missing = true;
    leveldb::DB* db = nullptr;
    auto status = leveldb::DB::Open(opts, dbpath.string(), &db);
    if (!status.ok()) {
        std::cerr << "leveldb open failed: " << status.ToString() << "\n";
        return 1;
    }

    // CRUD
    int errors = 0;
    auto check = [&](const std::string& name, bool ok) {
        std::cout << "  [" << (ok ? "OK  " : "FAIL") << "] " << name << "\n";
        if (!ok) errors++;
    };

    leveldb::WriteOptions wo;
    leveldb::ReadOptions ro;

    check("Put k1", db->Put(wo, "k1", "alpha").ok());
    check("Put k2", db->Put(wo, "k2", "beta").ok());
    check("Put k3", db->Put(wo, "k3", "gamma").ok());

    std::string val;
    check("Get k2", db->Get(ro, "k2", &val).ok() && val == "beta");

    check("Delete k1", db->Delete(wo, "k1").ok());
    auto get_after_del = db->Get(ro, "k1", &val);
    check("Get k1 after delete = NotFound", get_after_del.IsNotFound());

    // 迭代剩下的 keys
    int count = 0;
    auto* it = db->NewIterator(ro);
    for (it->SeekToFirst(); it->Valid(); it->Next()) count++;
    check("iterator count = 2 (k2, k3)", count == 2);
    delete it;

    delete db;

    // 清掉 disk
    fs::remove_all(dbpath);
    check("cleanup dir removed", !fs::exists(dbpath));

    std::cout << (errors == 0 ? "PASS" : "FAIL") << " (" << errors << " errors)\n";
    return errors;
}
