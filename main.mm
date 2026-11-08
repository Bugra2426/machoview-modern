// MachOView application entry point and headless native-build smoke test.
#include "disasm.h"
extern "C" {
#include "stuff/llvm.h"
}

int MVRunDataControllerTests(void);

static int MVRunDisassemblerTests(void)
{
  struct Test {
    const char *name;
    cpu_type_t architecture;
    cpu_subtype_t subtype;
    uint8_t bytes[8];
    size_t length;
    const char *mnemonic;
  } tests[] = {
    {"arm64", CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, {0xc0, 0x03, 0x5f, 0xd6}, 4, "ret"},
    {"arm64", CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, {0x3f, 0x23, 0x03, 0xd5}, 4, "paciasp"},
    {"arm64e", CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E, {0x3f, 0x23, 0x03, 0xd5}, 4, "paciasp"},
    {"arm64e with capability bits", CPU_TYPE_ARM64,
      (cpu_subtype_t)(CPU_SUBTYPE_ARM64E | CPU_SUBTYPE_LIB64), {0x3f, 0x23, 0x03, 0xd5}, 4, "paciasp"},
    {"x86_64", CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL, {0xc3, 0, 0, 0}, 1, "ret"},
    // Operand-bearing instructions invoke the op-info callback, whose ABI
    // changed in LLVM 16. A bare "ret" never exercised it.
    {"x86_64 operand callback", CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL, {0xe8, 0, 0, 0, 0}, 5, "call"},
    {"x86_64 immediate callback", CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL, {0xb8, 0x2a, 0, 0, 0}, 5, "mov"},
    {"arm64 operand callback", CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, {0x00, 0x00, 0x00, 0x94}, 4, "bl"},
  };
  for (auto &test : tests)
  {
    // Exercise the same CPU defaults and callbacks as section disassembly.
    LLVMDisasmContextRef context = test.architecture == CPU_TYPE_ARM64
      ? create_arm64_llvm_disassembler(test.subtype) : create_x86_64_llvm_disassembler();
    if (!context)
    {
      fprintf(stderr, "FAIL: bundled LLVM cannot create %s decoder\n", test.name);
      return 1;
    }
    char output[256] = {};
    size_t consumed = llvm_disasm_instruction(context, test.bytes, test.length,
                                              0x100000000ULL, output, sizeof(output));
    llvm_disasm_dispose(context);
    if (consumed != test.length || !strstr(output, test.mnemonic))
    {
      fprintf(stderr, "FAIL: %s decoded as '%s' (%zu bytes)\n", test.mnemonic, output, consumed);
      return 1;
    }
    printf("PASS: %s %s\n", test.name, test.mnemonic);
  }
  return 0;
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0)
    {
      @try {
        if (MVRunDisassemblerTests() != 0) return 1;
        if (MVRunDataControllerTests() != 0) return 1;
        printf("All native smoke tests passed.\n");
        return 0;
      }
      @catch (NSException *exception) {
        fprintf(stderr, "FAIL: %s\n", exception.description.UTF8String);
        return 1;
      }
    }
    return NSApplicationMain(argc, argv);
  }
}
