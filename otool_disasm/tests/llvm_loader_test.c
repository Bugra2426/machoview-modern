/* Portable tests for initialization, optional APIs and absent backends.
 * Include the real loader with only the dynamic-linker boundary replaced. */
#include <assert.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define dlopen test_dlopen
#define dlsym test_dlsym
#define dlclose test_dlclose
#include "../llvm.c"
#undef dlopen
#undef dlsym
#undef dlclose

static const char *mode;
static atomic_int open_count, close_count, init_count, cpu_count, dispose_count;
static int context;

static int unavailable(void)
{
    return strcmp(mode, "missing") == 0 || strcmp(mode, "incomplete") == 0;
}

static int optional_apis(void)
{
    return strcmp(mode, "minimal") != 0;
}

static void mock_initialize(void)
{
    atomic_fetch_add(&init_count, 1);
}

static LLVMDisasmContextRef mock_create(const char *triple, void *info, int tag,
    LLVMOpInfoCallback op, LLVMSymbolLookupCallback symbol)
{
    (void)info; (void)tag; (void)op; (void)symbol;
    assert(strcmp(triple, "arm64-apple-darwin") == 0);
    assert(atomic_load(&init_count) ==
           (strcmp(mode, "modern") == 0 ? 15 : optional_apis() ? 1 : 0));
    return &context;
}

static LLVMDisasmContextRef mock_create_cpu(const char *triple, const char *cpu,
    void *info, int tag, LLVMOpInfoCallback op, LLVMSymbolLookupCallback symbol)
{
    assert(strcmp(cpu, "apple-m1") == 0);
    atomic_fetch_add(&cpu_count, 1);
    return mock_create(triple, info, tag, op, symbol);
}

static void mock_dispose(LLVMDisasmContextRef dc)
{
    assert(dc == &context);
    atomic_fetch_add(&dispose_count, 1);
}

static size_t mock_disasm(LLVMDisasmContextRef dc, uint8_t *bytes, uint64_t size,
    uint64_t pc, char *out, size_t out_size)
{
    assert(dc == &context && bytes != NULL && size == 4);
    assert(pc == UINT64_C(0x100000000));
    snprintf(out, out_size, "ret");
    return 4;
}

static int mock_options(LLVMDisasmContextRef dc, uint64_t value)
{
    assert(dc == &context && value == 2);
    return 1;
}

static const char *mock_version(void)
{
    return "test LLVM";
}

void *test_dlopen(const char *path, int flags)
{
    assert(strcmp(path, "@executable_path/../Frameworks/libLTO.dylib") == 0);
    assert(flags == (RTLD_NOW | RTLD_LOCAL));
    atomic_fetch_add(&open_count, 1);
    return strcmp(mode, "missing") == 0 ? NULL : &context;
}

int test_dlclose(void *handle)
{
    assert(handle == &context);
    atomic_fetch_add(&close_count, 1);
    return 0;
}

void *test_dlsym(void *handle, const char *name)
{
    assert(handle == &context);
    if(strcmp(name, "LLVMCreateDisasm") == 0)
        return (void *)mock_create;
    if(strcmp(name, "LLVMDisasmDispose") == 0)
        return (void *)mock_dispose;
    if(strcmp(name, "LLVMDisasmInstruction") == 0)
        return strcmp(mode, "incomplete") == 0 ? NULL : (void *)mock_disasm;
    if(!optional_apis())
        return NULL;
    if(strcmp(name, "LLVMCreateDisasmCPU") == 0)
        return (void *)mock_create_cpu;
    if(strcmp(name, "LLVMSetDisasmOptions") == 0)
        return (void *)mock_options;
    if(strcmp(name, "lto_get_version") == 0)
        return (void *)mock_version;
    if(strcmp(name, "lto_initialize_disassembler") == 0)
        return strcmp(mode, "modern") == 0 ? NULL : (void *)mock_initialize;
    if(strncmp(name, "LLVMInitialize", 14) == 0)
        return (void *)mock_initialize;
    assert(!"unexpected symbol lookup");
    return NULL;
}

static void *exercise(void *unused)
{
    unsigned i;
    uint8_t bytes[4] = { 0xc0, 0x03, 0x5f, 0xd6 };
    char out[16];
    (void)unused;
    for(i = 0; i < 100; i++){
        LLVMDisasmContextRef dc = llvm_create_disasm("arm64-apple-darwin",
            i % 2 ? "apple-m1" : NULL, NULL, 1, NULL, NULL);
        assert((dc == NULL) == unavailable());
        assert(llvm_disasm_set_options(dc, 2) ==
               (!unavailable() && optional_apis()));
        strcpy(out, "stale");
        assert(llvm_disasm_instruction(dc, bytes, 4, UINT64_C(0x100000000),
            out, sizeof(out)) == (unavailable() ? 0 : 4));
        assert(strcmp(out, unavailable() ? "" : "ret") == 0);
        llvm_disasm_dispose(dc);
        assert(llvm_disasm_set_options(NULL, 2) == 0);
        assert(llvm_disasm_instruction(NULL, bytes, 4, 0, out, sizeof(out)) == 0);
        assert(out[0] == '\0');
        llvm_disasm_dispose(NULL);
        assert((llvm_disasm_version_string() != NULL) ==
               (!unavailable() && optional_apis()));
    }
    return NULL;
}

int main(int argc, char **argv)
{
    pthread_t threads[16];
    unsigned i;
    assert(argc == 2);
    mode = argv[1];
    for(i = 0; i < 16; i++)
        assert(pthread_create(&threads[i], NULL, exercise, NULL) == 0);
    for(i = 0; i < 16; i++)
        assert(pthread_join(threads[i], NULL) == 0);
    assert(atomic_load(&open_count) == 1);
    assert(atomic_load(&close_count) == (strcmp(mode, "incomplete") == 0));
    assert(atomic_load(&dispose_count) == (unavailable() ? 0 : 1600));
    assert(atomic_load(&cpu_count) ==
           (!unavailable() && optional_apis() ? 800 : 0));
    puts(mode);
    return 0;
}
