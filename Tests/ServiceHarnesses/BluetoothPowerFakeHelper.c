// Test fixture only. It simulates power results and blocking without loading Bluetooth.
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <limits.h>
int main(int argc, char **argv) {
    if (argc < 3 || strcmp(argv[1], "--island-bluetooth-power") != 0) return 64;
    if (strstr(argv[0], "hang")) {
        char path[PATH_MAX];
        const char *slash = strrchr(argv[0], '/');
        if (!slash) return 64;
        snprintf(path, sizeof(path), "%.*s/child.pid", (int)(slash - argv[0]), argv[0]);
        FILE *f = fopen(path, "w");
        if (f) { fprintf(f, "%d", getpid()); fclose(f); }
        signal(SIGTERM, SIG_IGN);
        for (;;) pause();
    }
    if (strstr(argv[0], "bad")) { puts("not JSON"); return 0; }
    puts((argc == 4 && strcmp(argv[2], "toggle") == 0 && strcmp(argv[3], "0") == 0)
        ? "{\"version\":1,\"enabled\":true}" : "{\"version\":1,\"enabled\":false}");
    return strstr(argv[0], "exit") ? 23 : 0;
}
