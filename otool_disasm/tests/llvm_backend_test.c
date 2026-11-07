/* Optional smoke test against a real libLLVM/libLTO supplied on the command
 * line. Only the test substitutes the bundle path; production never does. */
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static const char *backend_path;
static void *open_backend(const char *path, int flags);
#define dlopen open_backend
#include "../llvm.c"
#undef dlopen

static void *open_backend(const char *path, int flags)
{
    void *handle;
    assert(strcmp(path, "@executable_path/../Frameworks/libLTO.dylib") == 0);
    handle = dlopen(backend_path, flags);
    if(handle == NULL)
        fprintf(stderr, "%s\n", dlerror());
    return handle;
}

int main(int argc, char **argv)
{
    static const struct {
        const char *triple;
        const char *cpu;
        uint8_t bytes[4];
        size_t size;
        const char *mnemonic;
    } cases[] = {
        { "i386-apple-darwin10", "", { 0x90 }, 1, "nop" },
        { "x86_64-apple-darwin10", "", { 0xc3 }, 1, "ret" },
        { "armv7-apple-darwin10", "", { 0x00, 0x00, 0xa0, 0xe1 }, 4, "mov" },
        { "thumbv7-apple-darwin10", "", { 0x00, 0xbf }, 2, "nop" },
        { "arm64-apple-darwin10", "apple-m1", { 0xc0, 0x03, 0x5f, 0xd6 }, 4, "ret" },
        { "arm64-apple-darwin10", "apple-m1", { 0x3f, 0x23, 0x03, 0xd5 }, 4, "paciasp" }
    };
    size_t i;
    assert(argc == 2);
    backend_path = argv[1];
    for(i = 0; i < sizeof(cases) / sizeof(cases[0]); i++){
        char out[256];
        uint8_t bytes[4];
        LLVMDisasmContextRef dc = llvm_create_disasm(cases[i].triple,
            cases[i].cpu, NULL, 0, NULL, NULL);
        assert(dc != NULL);
        memcpy(bytes, cases[i].bytes, sizeof(bytes));
        llvm_disasm_set_options(dc, LLVMDisassembler_Option_PrintImmHex);
        assert(llvm_disasm_instruction(dc, bytes, cases[i].size,
            UINT64_C(0x100000000), out, sizeof(out)) == cases[i].size);
        assert(strstr(out, cases[i].mnemonic) != NULL);
        printf("%s:%s\n", cases[i].triple, out);
        llvm_disasm_dispose(dc);
    }
    return 0;
}
