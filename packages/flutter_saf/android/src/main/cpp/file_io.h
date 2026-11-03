#pragma once
#include <cerrno>
#include <climits>
#include <cstdint>
#include <unistd.h>
#include <vector>

// SAF document providers may return pipes or short reads. st_size is not a
// reliable length for those handles; consume them through EOF instead.
inline bool safReadToEnd(int fd, std::vector<int8_t>& bytes) {
    int8_t chunk[64 * 1024];
    while (true) {
        const auto count = read(fd, chunk, sizeof(chunk));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 || bytes.size() + count > INT_MAX) return false;
        if (count == 0) return true;
        bytes.insert(bytes.end(), chunk, chunk + count);
    }
}
