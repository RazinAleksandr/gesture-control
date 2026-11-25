// Tiny stable launcher. macOS ties Camera/Accessibility permissions to this binary,
// so it is built once; all logic lives in libGestureCore.dylib which can be rebuilt freely.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <mach-o/dyld.h>

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    char exe[PATH_MAX]; uint32_t sz = sizeof(exe);
    if (_NSGetExecutablePath(exe, &sz) != 0) return 1;
    char real[PATH_MAX];
    if (!realpath(exe, real)) return 1;
    char lib[PATH_MAX];
    const char *override = getenv("GC_CORE");
    if (override) {
        snprintf(lib, sizeof lib, "%s", override);
    } else {
        char *p = strstr(real, "/GestureControl.app/");
        if (!p) { fprintf(stderr, "launcher: unexpected location %s\n", real); return 1; }
        *p = 0;
        snprintf(lib, sizeof lib, "%s/libGestureCore.dylib", real);
    }
    void *h = dlopen(lib, RTLD_NOW);
    if (!h) { fprintf(stderr, "launcher: dlopen failed: %s\n", dlerror()); return 1; }
    int (*entry)(void) = (int (*)(void))dlsym(h, "gc_main");
    if (!entry) { fprintf(stderr, "launcher: gc_main not found\n"); return 1; }
    return entry();
}
