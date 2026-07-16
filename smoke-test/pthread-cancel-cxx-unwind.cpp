#include <pthread.h>
#include <signal.h>
#include <unistd.h>

#include <cstdio>

namespace {

constexpr int thread_count = 32;
int ready_pipe[2];
int block_pipe[2];
volatile int destructors;

struct guard {
    ~guard() { __sync_fetch_and_add(&destructors, 1); }
};

void* worker(void*) {
    guard cleanup;
    char byte = 'R';
    if (write(ready_pipe[1], &byte, 1) != 1) {
        _exit(20);
    }
    (void) read(block_pipe[0], &byte, 1);
    return nullptr;
}

} // namespace

int main() {
    alarm(30);
    if (pipe(ready_pipe) != 0 || pipe(block_pipe) != 0) {
        return 2;
    }

    pthread_t threads[thread_count];
    for (int i = 0; i < thread_count; ++i) {
        if (pthread_create(&threads[i], nullptr, worker, nullptr) != 0) {
            return 3;
        }
    }

    char byte;
    for (int i = 0; i < thread_count; ++i) {
        if (read(ready_pipe[0], &byte, 1) != 1) {
            return 4;
        }
    }
    for (int i = 0; i < thread_count; ++i) {
        if (pthread_cancel(threads[i]) != 0) {
            return 5;
        }
    }

    int canceled = 0;
    for (int i = 0; i < thread_count; ++i) {
        void* result = nullptr;
        if (pthread_join(threads[i], &result) != 0) {
            return 6;
        }
        canceled += result == PTHREAD_CANCELED;
    }

    std::printf("CANCEL canceled=%d destructors=%d\n", canceled, destructors);
    return canceled == thread_count && destructors == thread_count ? 0 : 1;
}
