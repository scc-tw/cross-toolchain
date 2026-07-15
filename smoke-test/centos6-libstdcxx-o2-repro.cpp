#include <fstream>

int main()
{
    std::ifstream input("/tmp/centos6-libstdcxx-o2-repro-input", std::ios::binary);
    return input.good() ? 0 : 1;
}
