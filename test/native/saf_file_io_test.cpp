#include "../../packages/flutter_saf/android/src/main/cpp/file_io.h"
#include <cassert>
#include <thread>
#include <cstdio>
#include <sys/stat.h>

int main() {
    int handles[2];
    assert(pipe(handles) == 0);
    struct stat info{};
    assert(fstat(handles[0], &info) == 0 && info.st_size == 0);
    std::vector<int8_t> expected(1024 * 1024 + 31);
    for (size_t i = 0; i < expected.size(); ++i) expected[i] = i % 127;
    std::thread producer([&] {
        size_t offset = 0;
        while (offset < expected.size()) {
            // Force many short reads, even though the consumer asks for 64K.
            const size_t amount = std::min(size_t(997), expected.size() - offset);
            const auto count = write(handles[1], expected.data() + offset, amount);
            assert(count > 0);
            offset += count;
            usleep(50);
        }
        close(handles[1]);
    });
    std::vector<int8_t> actual;
    assert(safReadToEnd(handles[0], actual));
    close(handles[0]);
    producer.join();
    assert(actual == expected);
    assert(!safReadToEnd(-1, actual));
    puts("PASS: zero-size pipe, short reads, EOF and read error");
}
