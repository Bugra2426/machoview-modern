#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include "stuff/llvm.h"

/*
 * The app embeds libLTO from the selected Xcode toolchain here. Never fall back
 * to a developer's installed Xcode (or a library found on the search path): it
 * may have the wrong architecture, API, or code signature. dyld expands
 * @executable_path for dlopen, including when the app is moved or translocated.
 */
#define LIB_LLVM "@executable_path/../Frameworks/libLTO.dylib"

static pthread_once_t llvm_once = PTHREAD_ONCE_INIT;
static void *llvm_handle;
static LLVMDisasmContextRef (*create)(const char *, void *, int,
    LLVMOpInfoCallback, LLVMSymbolLookupCallback);
static LLVMDisasmContextRef (*createCPU)(const char *, const char *, void *, int,
    LLVMOpInfoCallback, LLVMSymbolLookupCallback);
static void (*dispose)(LLVMDisasmContextRef);
static size_t (*disasm)(LLVMDisasmContextRef, uint8_t *, uint64_t, uint64_t,
    char *, size_t);
static int (*options)(LLVMDisasmContextRef, uint64_t);
static const char *(*version)(void);

static void
initialize_targets(void *handle)
{
    void (*initialize)(void);
    static const char *const targets[] = { "X86", "ARM", "AArch64" };
    static const char *const components[] = {
        "TargetInfo", "Target", "TargetMC", "AsmPrinter", "Disassembler"
    };
    size_t i, j;
    char name[80];

    initialize = (void (*)(void))dlsym(handle, "lto_initialize_disassembler");
    if(initialize != NULL){
        initialize();
        return;
    }

    /* Newer LLVM builds may expose only the per-target initialization API. */
    for(i = 0; i < sizeof(targets) / sizeof(targets[0]); i++){
        for(j = 0; j < sizeof(components) / sizeof(components[0]); j++){
            snprintf(name, sizeof(name), "LLVMInitialize%s%s",
                     targets[i], components[j]);
            initialize = (void (*)(void))dlsym(handle, name);
            if(initialize != NULL)
                initialize();
        }
    }
}

/* pthread_once publishes a complete API and finishes target registration before
 * any caller can create a context. A missing/incompatible backend stays absent
 * for this process; the app can still inspect files without disassembly. */
static void
load_llvm(void)
{
    void *handle = dlopen(LIB_LLVM, RTLD_NOW | RTLD_LOCAL);
    if(handle == NULL)
        return;

    create = (LLVMDisasmContextRef (*)(const char *, void *, int,
        LLVMOpInfoCallback, LLVMSymbolLookupCallback))
        dlsym(handle, "LLVMCreateDisasm");
    dispose = (void (*)(LLVMDisasmContextRef))
        dlsym(handle, "LLVMDisasmDispose");
    disasm = (size_t (*)(LLVMDisasmContextRef, uint8_t *, uint64_t, uint64_t,
        char *, size_t))dlsym(handle, "LLVMDisasmInstruction");
    if(create == NULL || dispose == NULL || disasm == NULL){
        create = NULL;
        dispose = NULL;
        disasm = NULL;
        dlclose(handle);
        return;
    }

    /* Optional APIs, not present in every libLTO release. */
    createCPU = (LLVMDisasmContextRef (*)(const char *, const char *, void *, int,
        LLVMOpInfoCallback, LLVMSymbolLookupCallback))
        dlsym(handle, "LLVMCreateDisasmCPU");
    options = (int (*)(LLVMDisasmContextRef, uint64_t))
        dlsym(handle, "LLVMSetDisasmOptions");
    version = (const char *(*)(void))dlsym(handle, "lto_get_version");
    initialize_targets(handle);
    /* Keep the library loaded for the lifetime of all contexts/callbacks. */
    llvm_handle = handle;
}

__private_extern__ LLVMDisasmContextRef
llvm_create_disasm(const char *TripleName, const char *CPU, void *DisInfo,
    int TagType, LLVMOpInfoCallback GetOpInfo,
    LLVMSymbolLookupCallback SymbolLookUp)
{
    pthread_once(&llvm_once, load_llvm);
    if(llvm_handle == NULL || TripleName == NULL)
        return NULL;
    if(CPU != NULL && *CPU != '\0' && createCPU != NULL)
        return createCPU(TripleName, CPU, DisInfo, TagType, GetOpInfo,
                         SymbolLookUp);
    return create(TripleName, DisInfo, TagType, GetOpInfo, SymbolLookUp);
}

__private_extern__ void
llvm_disasm_dispose(LLVMDisasmContextRef DC)
{
    pthread_once(&llvm_once, load_llvm);
    if(DC != NULL && dispose != NULL)
        dispose(DC);
}

__private_extern__ size_t
llvm_disasm_instruction(LLVMDisasmContextRef DC, uint8_t *Bytes,
    uint64_t BytesSize, uint64_t Pc, char *OutString, size_t OutStringSize)
{
    pthread_once(&llvm_once, load_llvm);
    if(OutString != NULL && OutStringSize != 0)
        OutString[0] = '\0';
    if(DC == NULL || disasm == NULL || Bytes == NULL || BytesSize == 0 ||
       OutString == NULL || OutStringSize == 0)
        return 0;
    return disasm(DC, Bytes, BytesSize, Pc, OutString, OutStringSize);
}

__private_extern__ int
llvm_disasm_set_options(LLVMDisasmContextRef DC, uint64_t Options)
{
    pthread_once(&llvm_once, load_llvm);
    if(DC == NULL || options == NULL)
        return 0;
    return options(DC, Options);
}

__private_extern__ const char *
llvm_disasm_version_string(void)
{
    pthread_once(&llvm_once, load_llvm);
    return version != NULL ? version() : NULL;
}
