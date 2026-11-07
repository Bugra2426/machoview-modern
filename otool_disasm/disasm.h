#ifndef _DISASM_H_
#define _DISASM_H_

#include <stdio.h>
#include <mach/machine.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/reloc.h>
#include "llvm-c/Disassembler.h"
#include "stuff/symbol.h"

#ifdef __cplusplus
extern "C" {
#endif

enum byte_sex {
    UNKNOWN_BYTE_SEX,
    BIG_ENDIAN_BYTE_SEX,
    LITTLE_ENDIAN_BYTE_SEX
};

/* Match the C implementation's enum bool ABI, not Objective-C BOOL, whose
 * size and underlying type differ between Intel and Apple Silicon. */
typedef int disasm_bool_t;

extern disasm_bool_t vflag;
extern disasm_bool_t Vflag;
extern disasm_bool_t qflag;
extern disasm_bool_t gflag;
extern disasm_bool_t in_thumb;

struct inst {
    uint64_t address;
    char *label;
    disasm_bool_t needs_tmp_label;
    char *tmp_label;
    disasm_bool_t print;
    disasm_bool_t has_raw_target_address;
    uint64_t raw_target_address;
};

struct dyld_bind_info {
    const char *segname;
    const char *sectname;
    uint64_t address;
    int bind_type;
    uint64_t addend;
    const char *dylibname;
    const char *symbolname;
    disasm_bool_t weak_import;
};

/* Select output for this thread; returns the previous stream (NULL = stdout).
 * Restore it before closing the stream. Decoder state still requires external
 * serialization for an entire section, including context creation/disposal. */
FILE *disasm_set_output(FILE *stream);

int sym_compare(struct symbol *sym1, struct symbol *sym2);
int rel_compare(struct relocation_info *rel1, struct relocation_info *rel2);
const char *guess_symbol(const uint64_t value,
    const struct symbol *sorted_symbols, const uint32_t nsorted_symbols,
    const disasm_bool_t verbose
#ifdef __cplusplus
    = 1
#endif
    );

LLVMDisasmContextRef create_i386_llvm_disassembler(void);
LLVMDisasmContextRef create_x86_64_llvm_disassembler(void);
LLVMDisasmContextRef create_arm_llvm_disassembler(cpu_subtype_t cpusubtype);
LLVMDisasmContextRef create_thumb_llvm_disassembler(cpu_subtype_t cpusubtype);
LLVMDisasmContextRef create_arm64_llvm_disassembler(cpu_subtype_t cpusubtype);
void delete_i386_llvm_disassembler(LLVMDisasmContextRef dc);
void delete_x86_64_llvm_disassembler(LLVMDisasmContextRef dc);
void delete_arm_llvm_disassembler(LLVMDisasmContextRef dc);
void delete_thumb_llvm_disassembler(LLVMDisasmContextRef dc);
void delete_arm64_llvm_disassembler(LLVMDisasmContextRef dc);
int llvm_disasm_set_options(LLVMDisasmContextRef DC, uint64_t Options);

uint32_t i386_disassemble(char *sect, uint32_t left, uint64_t addr,
    uint64_t sect_addr, enum byte_sex object_byte_sex,
    struct relocation_info *sorted_relocs, uint32_t nsorted_relocs,
    struct relocation_info *ext_relocs, uint32_t next_relocs,
    struct relocation_info *loc_relocs, uint32_t nloc_relocs,
    struct dyld_bind_info *dbi, uint64_t ndbi,
    struct nlist *symbols, struct nlist_64 *symbols64, uint32_t nsymbols,
    struct symbol *sorted_symbols, uint32_t nsorted_symbols,
    char *strings, uint32_t strings_size,
    uint32_t *indirect_symbols, uint32_t nindirect_symbols,
    cpu_type_t cputype, struct load_command *load_commands,
    uint32_t ncmds, uint32_t sizeofcmds, disasm_bool_t verbose,
    disasm_bool_t llvm_mc, LLVMDisasmContextRef i386_dc,
    LLVMDisasmContextRef x86_64_dc, char *object_addr, uint32_t object_size,
    struct inst *inst, struct inst *insts, uint32_t ninsts);

uint32_t arm_disassemble(char *sect, uint32_t left, uint32_t addr,
    uint32_t sect_addr, enum byte_sex object_byte_sex,
    struct relocation_info *sorted_relocs, uint32_t nsorted_relocs,
    struct nlist *symbols, uint32_t nsymbols,
    struct symbol *sorted_symbols, uint32_t nsorted_symbols,
    char *strings, uint32_t strings_size,
    uint32_t *indirect_symbols, uint32_t nindirect_symbols,
    struct load_command *load_commands, uint32_t ncmds, uint32_t sizeofcmds,
    cpu_subtype_t cpu_subtype, disasm_bool_t verbose,
    LLVMDisasmContextRef arm_dc, LLVMDisasmContextRef thumb_dc,
    char *object_addr, uint32_t object_size,
    struct data_in_code_entry *dices, uint32_t ndices, uint64_t seg_addr,
    struct inst *inst, struct inst *insts, uint32_t ninsts);

uint32_t arm64_disassemble(char *sect, uint32_t left, uint64_t addr,
    uint64_t sect_addr, enum byte_sex object_byte_sex,
    struct relocation_info *relocs, uint32_t nrelocs,
    struct relocation_info *ext_relocs, uint32_t next_relocs,
    struct relocation_info *loc_relocs, uint32_t nloc_relocs,
    struct dyld_bind_info *dbi, uint64_t ndbi,
    struct nlist_64 *symbols64, uint32_t nsymbols,
    struct symbol *sorted_symbols, uint32_t nsorted_symbols,
    char *strings, uint32_t strings_size,
    uint32_t *indirect_symbols, uint32_t nindirect_symbols,
    struct load_command *load_commands, uint32_t ncmds, uint32_t sizeofcmds,
    char *object_addr, uint32_t object_size, disasm_bool_t verbose,
    LLVMDisasmContextRef dc);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif
