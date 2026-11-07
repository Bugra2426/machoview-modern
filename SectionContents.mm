/*
 *  SectionContents.mm
 *  MachOView
 *
 *  Created by Bugra Karabudak on 15/09/2010.
 *
 */

#import "Common.h"
#import "SectionContents.h"
#import "CRTFootPrints.h"
#import "ReadWrite.h"
#import "DataController.h"

#include "disasm.h"

#define TAB_WIDTH 10

using namespace std;

// Capture decoder output in memory, not by redirecting process-wide stdout.
// The decoder's legacy symbol callbacks still require the section-level lock.
struct MVDisassemblyResources
{
  char *buffer = nullptr;
  size_t size = 0;
  FILE *stream;
  FILE *previous;
  LLVMDisasmContextRef arm = nullptr, thumb = nullptr, i386 = nullptr;
  LLVMDisasmContextRef x86_64 = nullptr, arm64 = nullptr;
  vector<struct symbol> symbols;

  MVDisassemblyResources() : stream(open_memstream(&buffer, &size)), previous(nullptr)
  {
    if (!stream) [NSException raise:NSMallocException format:@"Cannot capture disassembly output"];
    previous = disasm_set_output(stream);
  }
  ~MVDisassemblyResources()
  {
    disasm_set_output(previous);
    fclose(stream);
    free(buffer);
    if (arm) delete_arm_llvm_disassembler(arm);
    if (thumb) delete_thumb_llvm_disassembler(thumb);
    if (i386) delete_i386_llvm_disassembler(i386);
    if (x86_64) delete_x86_64_llvm_disassembler(x86_64);
    if (arm64) delete_arm64_llvm_disassembler(arm64);
    for (auto &symbol : symbols) free(symbol.name);
  }
};

//============================================================================
@implementation MachOLayout (SectionContents)

//-----------------------------------------------------------------------------
- (MVNode *)createPointersNode:(MVNode *)parent
                       caption:(NSString *)caption
                      location:(uint64_t)location
                        length:(uint64_t)length
{
  MVNodeSaver nodeSaver;
  MVNode * node = [parent insertChildWithDetails:caption location:location length:length saver:nodeSaver]; 
  
  NSRange range = NSMakeRange(location,0);
  NSString * lastReadHex;

  while (NSMaxRange(range) < location + length)
  {
    uint32_t ptr = [dataController read_uint32:range lastReadHex:&lastReadHex];
    NSString * symbolName = [NSString stringWithFormat:@"%@->%@",
                             [self findSymbolAtRVA:[self fileOffsetToRVA:range.location]],
                             [self findSymbolAtRVA:ptr]];
    
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"Pointer"
                           :symbolName];
    
    [node.details setAttributes:MVMetaDataAttributeName,symbolName,nil];
    
    symbolNames[@([self fileOffsetToRVA:range.location])] = symbolName;
  }
  
  return node;
}

//-----------------------------------------------------------------------------
- (MVNode *)createPointers64Node:(MVNode *)parent
                         caption:(NSString *)caption
                        location:(uint64_t)location
                          length:(uint64_t)length
{
  MVNodeSaver nodeSaver;
  MVNode * node = [parent insertChildWithDetails:caption location:location length:length saver:nodeSaver]; 
  
  NSRange range = NSMakeRange(location,0);
  NSString * lastReadHex;

  while (NSMaxRange(range) < location + length)
  {
    uint64_t ptr = [dataController read_uint64:range lastReadHex:&lastReadHex];
    NSString * symbolName = [NSString stringWithFormat:@"%@->%@",
                             [self findSymbolAtRVA64:[self fileOffsetToRVA64:range.location]],
                             [self findSymbolAtRVA64:ptr]];
    
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"Pointer"
                           :symbolName];
    
    [node.details setAttributes:MVMetaDataAttributeName,symbolName,nil];
    
    symbolNames[@([self fileOffsetToRVA64:range.location])] = symbolName;
  }
  
  return node;
}

//-----------------------------------------------------------------------------
-(MVNode *)createCStringsNode:(MVNode *)parent
                      caption:(NSString *)caption
                     location:(uint64_t)location
                       length:(uint64_t)length
{
  MVNodeSaver nodeSaver;
  MVNode * node = [parent insertChildWithDetails:caption location:location length:length saver:nodeSaver]; 
  
  NSRange range = NSMakeRange(location,0);
  NSString * lastReadHex;

  while (NSMaxRange(range) < location + length)
  {
    NSString * symbolName = [dataController read_string:range lastReadHex:&lastReadHex];
    
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :[NSString stringWithFormat:@"CString (length:%lu)", symbolName.length]
                           :symbolName];
    
    [node.details setAttributes:MVMetaDataAttributeName,symbolName,nil];
    
    // fill in lookup table with C Strings
    if (self.is64bit == NO)
    {
      uint32_t rva = [self fileOffsetToRVA:range.location];
      symbolNames[@(rva)] = [NSString stringWithFormat:@"0x%X:\"%@\"", rva, symbolName];
    }
    else
    {
      uint64_t rva64 = [self fileOffsetToRVA64:range.location];
      symbolNames[@(rva64)] = [NSString stringWithFormat:@"0x%llX:\"%@\"", rva64, symbolName];
    }
  }
  
  return node;
}

//-----------------------------------------------------------------------------
-(MVNode *)createLiteralsNode:(MVNode *)parent
                      caption:(NSString *)caption
                     location:(uint64_t)location
                       length:(uint64_t)length
                       stride:(uint32_t)stride
{
  MVNodeSaver nodeSaver;
  MVNode * node = [parent insertChildWithDetails:caption location:location length:length saver:nodeSaver]; 
  
  NSRange range = NSMakeRange(location,0);
  NSString * lastReadHex;

  while (NSMaxRange(range) < location + length)
  {
    NSData * data = [dataController read_bytes:range length:stride lastReadHex:&lastReadHex];

    NSString * literalStr;
    switch (stride)
    {
      case sizeof(float): 
      {
        double num = *(float *)data.bytes;
        literalStr = [NSString stringWithFormat:@"%.16g", num];
      } break;
      
      case sizeof(double): 
      {
        double num = *(double *)data.bytes; 
        literalStr = [NSString stringWithFormat:@"%.16g", num];
      } break;
        
      case 16:
      {
        // S_16BYTE_LITERALS is a file format width, not sizeof(long double).
        // Apple Silicon long double is 8 bytes; don't interpret x86 extended
        // precision or arbitrary 128-bit literals using the host's ABI.
        literalStr = [NSString stringWithFormat:@"0x%@ (128-bit literal)", lastReadHex];
      } break;
      default:
        literalStr = [NSString stringWithFormat:@"0x%@", lastReadHex];
        break;
    }
    
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"Floating Point Number"
                           :literalStr];
    
    // fill in lookup table with string literals
    if (self.is64bit == NO)
    {
      uint32_t rva = [self fileOffsetToRVA:range.location];
      symbolNames[@(rva)] = [NSString stringWithFormat:@"0x%X:%@f", rva, literalStr]; 
    }
    else
    {
      uint64_t rva64 = [self fileOffsetToRVA64:range.location];
      symbolNames[@(rva64)] = [NSString stringWithFormat:@"0x%llX:%@f", rva64, literalStr]; 
    }
  }
  return node;
  
}

//-----------------------------------------------------------------------------
- (MVNode *)createIndPointersNode:(MVNode *)parent
                          caption:(NSString *)caption
                         location:(uint64_t)location
                           length:(uint64_t)length
{
  MVNodeSaver nodeSaver;
  MVNode * node = [parent insertChildWithDetails:caption location:location length:length saver:nodeSaver]; 
  
  NSRange range = NSMakeRange(location,0);
  NSString * lastReadHex;

  while (NSMaxRange(range) < location + length)
  {
    [dataController read_uint32:range lastReadHex:&lastReadHex];
    NSString * symbolName = [self findSymbolAtRVA:[self fileOffsetToRVA:range.location]];
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"Indirect Pointer"
                           :symbolName];
    
    [node.details setAttributes:MVMetaDataAttributeName,symbolName,nil];
  }
  
  return node;
}

//-----------------------------------------------------------------------------
- (MVNode *)createIndPointers64Node:(MVNode *)parent
                            caption:(NSString *)caption
                           location:(uint64_t)location
                             length:(uint64_t)length
{
  MVNodeSaver nodeSaver;
  MVNode * node = [parent insertChildWithDetails:caption location:location length:length saver:nodeSaver]; 
  
  NSRange range = NSMakeRange(location,0);
  NSString * lastReadHex;

  while (NSMaxRange(range) < location + length)
  {
    [dataController read_uint64:range lastReadHex:&lastReadHex];
    NSString * symbolName = [self findSymbolAtRVA64:[self fileOffsetToRVA64:range.location]];
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"Indirect Pointer"
                           :symbolName];
    
    [node.details setAttributes:MVMetaDataAttributeName,symbolName,nil];
  }
  
  return node;
}

//-----------------------------------------------------------------------------
- (MVNode *)createIndStubsNode:(MVNode *)parent
                       caption:(NSString *)caption
                      location:(uint64_t)location
                        length:(uint64_t)length
                        stride:(uint32_t)stride
{
  MVNodeSaver nodeSaver;
  MVNode * node = [parent insertChildWithDetails:caption location:location length:length saver:nodeSaver]; 
  
  NSRange range = NSMakeRange(location,0);
  NSString * lastReadHex;

  while (NSMaxRange(range) < location + length)
  {
    [dataController read_bytes:range length:stride lastReadHex:&lastReadHex];
    NSString * symbolName = [self findSymbolAtRVA:[self fileOffsetToRVA:range.location]];
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"Indirect Stub"
                           :symbolName];
    
    [node.details setAttributes:MVMetaDataAttributeName,symbolName,nil];
  }
  
  return node;
}

//-----------------------------------------------------------------------------
- (MVNode *)createIndStubs64Node:(MVNode *)parent
                         caption:(NSString *)caption
                        location:(uint64_t)location
                          length:(uint64_t)length
                          stride:(uint32_t)stride
{
  MVNodeSaver nodeSaver;
  MVNode * node = [parent insertChildWithDetails:caption location:location length:length saver:nodeSaver]; 
  
  NSRange range = NSMakeRange(location,0);
  NSString * lastReadHex;

  while (NSMaxRange(range) < location + length)
  {
    [dataController read_bytes:range length:stride lastReadHex:&lastReadHex];
    NSString * symbolName = [self findSymbolAtRVA64:[self fileOffsetToRVA64:range.location]];
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"Indirect Stub"
                           :symbolName];
    
    [node.details setAttributes:MVMetaDataAttributeName,symbolName,nil];
  }
  
  return node;
}


//============================= X86 =========================
//===========================================================
static AsmFootPrint const classicStubHelperX86 =
{
    {1, 0x68}, GAP(4),                        // pushl   $foo$lazy_ptr
    {1, 0xE9}, GAP(4),                        // jmp     helperhelper
};

static AsmFootPrint const hybridStubHelperX86 =
{
  {1, 0x68}, GAP(4),                        // pushl   $lazy-info-offset
    {1, 0x68}, GAP(4),                        // pushl   $foo$lazy_ptr
    {1, 0xE9}, GAP(4),                        // jmp     dyld_hybrid_stub_binding_helper
    {1, 0x90},                                // nop
};

static AsmFootPrint const hybridStubHelperHelperX86 =
{
  {2, 0x83, 0x3D}, GAP(4), {1, 0x00},       // cmpl    $0x00,_fast_lazy_bind
    {2, 0x75,    0x0D},                          // jne     $0x0D
    {4, 0x89,    0x44, 0x24, 0x04},              // movl    %eax,4(%esp)
    {1, 0x58},                                // popl    %eax
    {3, 0x87, 0x04, 0x24},                    // xchgl   (%esp),%eax
    {1, 0xE9}, GAP(4),                        // jmpl    dyld_stub_binding_helper
    {3, 0x83, 0xC4, 0x04},                    // addl    $0x04,%esp
    {1, 0x68}, GAP(4),                        // pushl   imageloadercache
    {2, 0xFF, 0x25}, GAP(4),                  // jmp     *_fast_lazy_bind(%rip)
};

static AsmFootPrint const fastStubHelperX86 =
{
  {1, 0x68}, GAP(4),                        // pushl   $lazy-info-offset
  {1, 0xE9}, GAP(4),                        // jmp     helperhelper
};

static AsmFootPrint const fastStubHelperHelperX86 =
{
    {1, 0x68}, GAP(4),                        // pushl   imageloadercache
    {2, 0xFF, 0x25}, GAP(4),                  // jmp     *_fast_lazy_bind
    {1, 0x90},                                // nop
};

//=========================== X86_64 ========================
//===========================================================

static AsmFootPrint const classicStubHelperX86_64 =
{
  {3, 0x4C,    0x8D, 0x1D}, GAP(4),            // lea    foo$lazy_ptr(%rip),%r11
    {1, 0xE9}, GAP(4),                        // jmp    dyld_stub_binding_helper
};


static AsmFootPrint const hybridStubHelperX86_64 =
{
  {1, 0x68}, GAP(4),                        // pushq  $lazy-info-offset
    {3, 0x4C, 0x8D, 0x1D}, GAP(4),            // lea    foo$lazy_ptr(%rip),%r11
    {1, 0xE9}, GAP(4),                        // jmp    helper-helper
    {1, 0x90},                                // nop
};

static AsmFootPrint const hybridStubHelperHelperX86_64 =
{
  {3, 0x48, 0x83, 0x3D}, GAP(4), {1, 0x00}, // cmpq   $0x00,_fast_lazy_bind
    {2, 0x74,    0x0F},                          // je     $0x0F
    {3, 0x4C, 0x8D,    0x1D}, GAP(4),            // leaq   imageCache(%rip),%r11
    {2, 0x41,    0x53},                          // pushq  %r11
    {2, 0xFF,    0x25}, GAP(4),                  // jmp    *_fast_lazy_bind(%rip)
    {4, 0x48, 0x83, 0xC4, 0x08},              // addq   $8,%rsp
    {1, 0xE9}, GAP(4),                        // jmp    dyld_stub_binding_helper
};


static AsmFootPrint const fastStubHelperX86_64 =
{
  {1, 0x68}, GAP(4),                        // pushq  $lazy-info-offset
    {1, 0xE9}, GAP(4),                        // jmp    helperhelper
};

static AsmFootPrint const fastStubHelperHelperX86_64 =
{
  {3, 0x4C, 0x8D, 0x1D}, GAP(4),            // leaq   dyld_mageLoaderCache(%rip),%r11
  {2, 0x41, 0x53},                          // pushq  %r11
  {2, 0xFF, 0x25}, GAP(4),                  // jmp    *_fast_lazy_bind(%rip)
  {1, 0x90},                                // nop
};

//=========================== ARM ===========================
//===========================================================
static AsmFootPrint const fastStubHelperARM =
{
  {4, 0xe5, 0x9f, 0xc0, 0x00},              // ldr  ip, [pc, #0]
    {4, 0xea, 0x00, 0x00, 0x00},              // b    _helperhelper
  GAP(4),                                   // lazy binding info
};

static AsmFootPrint const fastStubHelperHelperARM =
{
  // push lazy-info-offset
  {4, 0xe5, 0x2d, 0xc0, 0x04},              // str ip, [sp, #-4]!
  // push address of dyld_mageLoaderCache
  {4, 0xe5, 0x9f, 0xc0, 0x10},              // ldr    ip, L1
  {4, 0xe0, 0x8f, 0xc0, 0x0c},              // add    ip, pc, ip
  {4, 0xe5, 0x2d, 0xc0, 0x04},              // str ip, [sp, #-4]!
  // jump through _fast_lazy_bind
  {4, 0xe5, 0x9f, 0xc0, 0x08},              // ldr    ip, L2
  {4, 0xe0, 0x8f, 0xc0, 0x0c},              // add    ip, pc, ip
  {4, 0xe5, 0x9c, 0xf0, 0x00},              // ldr    pc, [ip]
  GAP(4),                                   // L1: .long fFastStubGOTAtom - (helperhelper+16)
  GAP(4),                                   // L2: .long _fast_lazy_bind - (helperhelper+28)
};


//-----------------------------------------------------------------------------
// __stub_helper:
//
//  StubHelperHelper
//  StubHelper
//  StubHelper
//  ...

// __symbol_stub1:
//  FF 25 <relative to indirect>
//  ...
//-----------------------------------------------------------------------------
- (MVNode *)createStubHelperNode:(MVNode *)parent
                         caption:(NSString *)caption
                        location:(uint64_t)location
                          length:(uint64_t)length
{
  MVNodeSaver nodeSaver;
  MVNode * node = [parent insertChildWithDetails:caption location:location length:length saver:nodeSaver]; 
  
  NSRange range = NSMakeRange(location,0);
  NSString * lastReadHex;
  
  NSData * data;
  uint32_t address;

  if ([self matchAsmAtOffset:range.location 
                asmFootPrint:hybridStubHelperHelperX86 
                   lineCount:sizeof(hybridStubHelperHelperX86)/FOOTPRINT_STRIDE])
  {
    data = [dataController read_bytes:range length:7 lastReadHex:&lastReadHex];
    address = *(uint32_t *)((uint8_t *)data.bytes + 2);
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"cmpl  $0x00,_fast_lazy_bind"
                           :[self findSymbolAtRVA:address]];

    [dataController read_bytes:range length:2 lastReadHex:&lastReadHex];
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"jne  $0x0D"
                           :@""];

    [dataController read_bytes:range length:4 lastReadHex:&lastReadHex];
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"movl  %eax,4(%esp)"
                           :@""];

    [dataController read_bytes:range length:1 lastReadHex:&lastReadHex];
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"popl  %eax"
                           :@""];

    [dataController read_bytes:range length:3 lastReadHex:&lastReadHex];
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"xchgl  (%esp),%eax"
                           :@""];

    data = [dataController read_bytes:range length:5 lastReadHex:&lastReadHex];
    address = [self fileOffsetToRVA:NSMaxRange(range) + *(uint32_t *)((uint8_t *)data.bytes + 1)];
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"jmpl  dyld_stub_binding_helper"
                           :[self findSymbolAtRVA:address]];

    [dataController read_bytes:range length:3 lastReadHex:&lastReadHex];
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"addl  $0x04,%esp"
                           :@""];

    data = [dataController read_bytes:range length:5 lastReadHex:&lastReadHex];
    address = *(uint32_t *)((uint8_t *)data.bytes + 1);
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"pushl  imageloadercache"
                           :[self findSymbolAtRVA:address]];

    data = [dataController read_bytes:range length:6 lastReadHex:&lastReadHex];
    address = *(uint32_t *)((uint8_t *)data.bytes + 2);
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"jmp  *_fast_lazy_bind(%rip)"
                           :[self findSymbolAtRVA:address]];
    
    [node.details setAttributes:MVUnderlineAttributeName,@"YES",nil];
    
  }
  else if ([self matchAsmAtOffset:range.location 
                     asmFootPrint:fastStubHelperHelperX86 
                        lineCount:sizeof(fastStubHelperHelperX86)/FOOTPRINT_STRIDE])
  {
    data = [dataController read_bytes:range length:5 lastReadHex:&lastReadHex];
    address = *(uint32_t *)((uint8_t *)data.bytes + 1);
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"pushl  imageloadercache"
                           :[self findSymbolAtRVA:address]];
    
    data = [dataController read_bytes:range length:6 lastReadHex:&lastReadHex];
    address = *(uint32_t *)((uint8_t *)data.bytes + 2);
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"jmp  *_fast_lazy_bind"
                           :[self findSymbolAtRVA:address]];

    [dataController read_bytes:range length:1 lastReadHex:&lastReadHex];
    [node.details appendRow:[NSString stringWithFormat:@"%.8lX", range.location]
                           :lastReadHex
                           :@"nop"
                           :@""];
    
    [node.details setAttributes:MVUnderlineAttributeName,@"YES",nil];
    
  }
  
  return node;
}


//-----------------------------------------------------------------------------
- (MVNode *)createTextNode:(MVNode *)parent
                   caption:(NSString *)caption
                  location:(uint64_t)location
                    length:(uint64_t)length
                    reloff:(uint64_t)reloff
                    nreloc:(uint32_t)nreloc
                 extreloff:(uint64_t)extreloff
                   nextrel:(uint32_t)nextrel
                 locreloff:(uint64_t)locreloff
                   nlocrel:(uint32_t)nlocrel
{
  MVNodeSaver nodeSaver;
  MVNode * node = [parent insertChildWithDetails:caption location:location length:length saver:nodeSaver]; 
  
  // accumulate search info
  NSUInteger bookmark = node.details.rowCount;
  NSString * symbolName = nil;
  
  if (length == 0) // prevent from attempting to parse zero length sections
  {
    return node;
  }
  
  // Keep the legacy decoder's shared callback state isolated between documents.
  @synchronized([MachOLayout class])
  {
  // Snapshot the preference once per section; the UI never mutates decoder
  // globals while background instructions are being decoded.
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  qflag = [defaults objectForKey:@"UseLLVMDisassembler"] == nil ||
          [defaults boolForKey:@"UseLLVMDisassembler"];
  NSUInteger fileLength = dataController.fileData.length;
  if (location > fileLength || length > fileLength - location || length > UINT32_MAX)
    [NSException raise:NSRangeException format:@"Code section is outside the file or too large"];

  // prepare disassembler params
  //===========================================================================
  MATCH_STRUCT(mach_header,imageOffset);
  
  char *                      ot_sect = (char *)(dataController.fileData).bytes + location;
  uint32_t                    ot_left = (uint32_t)length;
  uint64_t                    ot_addr = (self.is64bit == NO ? [self fileOffsetToRVA:location] : [self fileOffsetToRVA64:location]);
  uint64_t                    ot_sect_addr = ot_addr;
  uint64_t                    ot_seg_addr = ot_addr;
  enum byte_sex               ot_object_byte_sex = LITTLE_ENDIAN_BYTE_SEX; // the only one we support so far
  struct nlist *              ot_symbols = (symbols.empty() ? NULL : const_cast<struct nlist *>(symbols[0]));
  struct nlist_64 *           ot_symbols64 = (symbols_64.empty() ? NULL : const_cast<struct nlist_64 *>(symbols_64[0]));
  uint32_t                    ot_nsymbols = (uint32_t)(self.is64bit == NO ? symbols.size() : symbols_64.size());
  char *                      ot_strings = (char *)strtab;
  uint32_t                    ot_strings_size = 0;
  for (const auto *command : commands)
  {
    if (command->cmd == LC_SYMTAB)
    {
      const auto *table = reinterpret_cast<const struct symtab_command *>(command);
      if (imageOffset <= fileLength && table->stroff <= fileLength - imageOffset &&
          table->strsize <= fileLength - imageOffset - table->stroff)
        ot_strings_size = table->strsize;
      break;
    }
  }
  uint32_t *                  ot_indirect_symbols = (isymbols.empty() ? NULL : const_cast<uint32_t *>(isymbols[0]));
  uint32_t                    ot_nindirect_symbols = (uint32_t)isymbols.size();
  struct load_command *       ot_load_commands = commands.empty() ? nullptr : (struct load_command *)(commands[0]);
  uint32_t                    ot_ncmds = (uint32_t)commands.size();
  uint32_t                    ot_sizeofcmds = mach_header->sizeofcmds;
  cpu_type_t                  ot_cputype = mach_header->cputype;
  cpu_subtype_t               ot_cpu_subtype = mach_header->cpusubtype;
  BOOL                        ot_verbose = TRUE;
  BOOL                        ot_llvm_mc = FALSE; /* disassemble as llvm-mc will assemble */

  struct data_in_code_entry * ot_dices = (dices.empty() ? NULL : const_cast<struct data_in_code_entry *>(dices[0]));
  uint32_t                    ot_ndices = (uint32_t)dices.size();
  char *                      ot_object_addr = (char *)mach_header;
  uint32_t                    ot_object_size = (uint32_t)imageSize;

  #pragma message "TODO"
  struct dyld_bind_info *     ot_dbi = NULL;
  uint64_t                    ot_ndbi = 0;
  

  MVDisassemblyResources output;
  LLVMDisasmContextRef &ot_arm_dc = output.arm;
  LLVMDisasmContextRef &ot_thumb_dc = output.thumb;
  LLVMDisasmContextRef &ot_i386_dc = output.i386;
  LLVMDisasmContextRef &ot_x86_64_dc = output.x86_64;
  LLVMDisasmContextRef &ot_arm64_dc = output.arm64;
  
  
  //===========================================================================
  if((qflag || gflag) && mach_header->cputype == CPU_TYPE_ARM)
  {
    ot_arm_dc = create_arm_llvm_disassembler(mach_header->cpusubtype);
    ot_thumb_dc = create_thumb_llvm_disassembler(mach_header->cpusubtype);
    llvm_disasm_set_options(ot_arm_dc, LLVMDisassembler_Option_PrintImmHex);
    llvm_disasm_set_options(ot_thumb_dc, LLVMDisassembler_Option_PrintImmHex);
  }
  if(mach_header->cputype == CPU_TYPE_ARM64)
  {
    ot_arm64_dc = create_arm64_llvm_disassembler(mach_header->cpusubtype);
    llvm_disasm_set_options(ot_arm64_dc, LLVMDisassembler_Option_PrintImmHex);
  }
  if((qflag || gflag) && mach_header->cputype == CPU_TYPE_I386)
  {
    ot_i386_dc = create_i386_llvm_disassembler();
    llvm_disasm_set_options(ot_i386_dc, LLVMDisassembler_Option_PrintImmHex);
  }
  if((qflag || gflag) && mach_header->cputype == CPU_TYPE_X86_64)
  {
    ot_x86_64_dc = create_x86_64_llvm_disassembler();
    llvm_disasm_set_options(ot_x86_64_dc, LLVMDisassembler_Option_PrintImmHex);
  }
  // A damaged/missing backend must not abort Debug builds either. The C
  // decoders handle NULL contexts by showing raw bytes instead of assembly.
  if ((mach_header->cputype == CPU_TYPE_ARM64 && !ot_arm64_dc) ||
      ((qflag || gflag) &&
       ((mach_header->cputype == CPU_TYPE_ARM && (!ot_arm_dc || !ot_thumb_dc)) ||
        (mach_header->cputype == CPU_TYPE_I386 && !ot_i386_dc) ||
        (mach_header->cputype == CPU_TYPE_X86_64 && !ot_x86_64_dc))))
    [node.details appendRow:@"":@"":@"LLVM backend unavailable":@"Showing raw instructions"];
  
  if(mach_header->cputype == CPU_TYPE_ARM &&
     (mach_header->cpusubtype == CPU_SUBTYPE_ARM_V7 ||
      mach_header->cpusubtype == CPU_SUBTYPE_ARM_V7F ||
      mach_header->cpusubtype == CPU_SUBTYPE_ARM_V7S ||
      mach_header->cpusubtype == CPU_SUBTYPE_ARM_V7K ||
      mach_header->cpusubtype == CPU_SUBTYPE_ARM_V8))
  {
    //if(sect_flags & S_SYMBOL_STUBS)
    //  in_thumb = FALSE;
    //else
    in_thumb = TRUE;
  }
  else
  {
    in_thumb = FALSE;
  }
  
  //===========================================================================
  // collect thumb symbols
  set<uint64_t> thumbSymbols;
  if (mach_header->cputype == CPU_TYPE_ARM ||
      mach_header->cputype == CPU_TYPE_ARM64)
  {
    for(uint32_t i = 0; i < ot_nsymbols; ++i)
    {
      uint8_t n_type;
      uint16_t n_desc;
      uint64_t n_value;
      
      if(self.is64bit == NO)
      {
        struct nlist const * nlist = symbols.at(i);
        n_type = nlist->n_type;
        n_desc = nlist->n_desc;
        n_value = nlist->n_value;
      }
      else
      {
        struct nlist_64 const * nlist_64 = symbols_64.at(i);
        n_type = nlist_64->n_type;
        n_desc = nlist_64->n_desc;
        n_value = nlist_64->n_value;
      }
      
      if((n_type & N_TYPE) == N_SECT && (n_desc & N_ARM_THUMB_DEF))
      {
        thumbSymbols.insert(n_value);
      }
    }
  }
  
  //===========================================================================
  /* create aligned, sorted symbol entries */
  vector<struct symbol> &sorted_symbols = output.symbols;

  NSEnumerator * enumerator = [symbolNames keyEnumerator];
  id key;
  while ((key = [enumerator nextObject]) != nil) 
  {
    NSNumber * symbolIndex = (NSNumber *)key;
    
    // skip external symbols
    if ((self.is64bit == NO && (int32_t)symbolIndex.unsignedLongValue < 0) ||
        (int64_t)symbolIndex.unsignedLongLongValue < 0)
    {
      continue;
    }

    struct symbol symbol;
    symbol.name = strdup(CSTRING(symbolNames[key]));
    symbol.n_value = symbolIndex.unsignedLongLongValue;
    symbol.is_thumb = (thumbSymbols.find(symbol.n_value) != thumbSymbols.end());
    
    sorted_symbols.push_back(symbol);
  }
  
  if (sorted_symbols.size() > 1)
    qsort(sorted_symbols.data(), sorted_symbols.size(), sizeof(struct symbol),
          (int (*)(const void *, const void *))sym_compare);

  struct symbol *           ot_sorted_symbols = sorted_symbols.data();
  uint32_t                  ot_nsorted_symbols = (uint32_t)sorted_symbols.size();
  
  //===========================================================================
  /* collect relocations entries */
 
  struct relocation_info *  ot_relocs = (struct relocation_info *)((char *)(dataController.fileData).bytes + reloff);
  uint32_t                  ot_nrelocs = nreloc;

  struct relocation_info *  ot_ext_relocs = (struct relocation_info *)((char *)(dataController.fileData).bytes + extreloff);
  uint32_t                  ot_next_relocs = nextrel;
  
  struct relocation_info *  ot_loc_relocs = (struct relocation_info *)((char *)(dataController.fileData).bytes + locreloff);
  uint32_t                  ot_nloc_relocs = nlocrel;

  
  //===========================================================================
  /*
    start = (uint8_t *)(object_addr + dyld_info.bind_off);
    end = start + dyld_info.bind_size;
    get_dyld_bind_info(start, end, dylibs, ndylibs, segs, nsegs, segs64, nsegs64, dbi, ndbi);
  */
  //===========================================================================

  do
  {
    // catch thread cancellation request
    if (backgroundThread.cancelled)
    {
      break;
    }
    
    NSUInteger nAsmLine = 0;
    do
    {
      @autoreleasepool {
      if (backgroundThread.cancelled) { ot_left = 0; break; }
      // Reuse the memory stream allocation across instructions.
      if (fseek(output.stream, 0, SEEK_SET) != 0)
        [NSException raise:NSInternalInconsistencyException format:@"Cannot reset disassembly stream"];
      uint32_t parsed_bytes;
      
      try
      {
        
        parsed_bytes =
        (mach_header->cputype == CPU_TYPE_I386 ||
         mach_header->cputype == CPU_TYPE_X86_64
         ? i386_disassemble(
                            ot_sect,
                            ot_left,
                            ot_addr,
                            ot_sect_addr,
                            ot_object_byte_sex,
                            ot_relocs,
                            ot_nrelocs,
                            ot_ext_relocs,
                            ot_next_relocs,
                            ot_loc_relocs,
                            ot_nloc_relocs,
                            ot_dbi,
                            ot_ndbi,
                            ot_symbols,
                            ot_symbols64,
                            ot_nsymbols,
                            ot_sorted_symbols,
                            ot_nsorted_symbols,
                            ot_strings,
                            ot_strings_size,
                            ot_indirect_symbols,
                            ot_nindirect_symbols,
                            ot_cputype,
                            ot_load_commands,
                            ot_ncmds,
                            ot_sizeofcmds,
                            ot_verbose,
                            ot_llvm_mc,
                            ot_i386_dc,
                            ot_x86_64_dc,
                            ot_object_addr,
                            ot_object_size,
                            NULL,
                            NULL,
                            0
                            )
         : mach_header->cputype == CPU_TYPE_ARM
         ? arm_disassemble(
                           ot_sect,
                           ot_left,
                           (uint32_t)ot_addr,
                           (uint32_t)ot_sect_addr,
                           ot_object_byte_sex,
                           ot_relocs,
                           ot_nrelocs,
                           ot_symbols,
                           ot_nsymbols,
                           ot_sorted_symbols,
                           ot_nsorted_symbols,
                           ot_strings,
                           ot_strings_size,
                           ot_indirect_symbols,
                           ot_nindirect_symbols,
                           ot_load_commands,
                           ot_ncmds,
                           ot_sizeofcmds,
                           ot_cpu_subtype,
                           ot_verbose,
                           ot_arm_dc,
                           ot_thumb_dc,
                           ot_object_addr,
                           ot_object_size,
                           ot_dices,
                           ot_ndices,
                           ot_seg_addr,
                           NULL,
                           NULL,
                           0
                           )
         : mach_header->cputype == CPU_TYPE_ARM64
         ? arm64_disassemble(
                           ot_sect,
                           ot_left,
                           ot_addr,
                           ot_sect_addr,
                           ot_object_byte_sex,
                           ot_relocs,
                           ot_nrelocs,
                           ot_ext_relocs,
                           ot_next_relocs,
                           ot_loc_relocs,
                           ot_nloc_relocs,
                           ot_dbi,
                           ot_ndbi,
                           ot_symbols64,
                           ot_nsymbols,
                           ot_sorted_symbols,
                           ot_nsorted_symbols,
                           ot_strings,
                           ot_strings_size,
                           ot_indirect_symbols,
                           ot_nindirect_symbols,
                           ot_load_commands,
                           ot_ncmds,
                           ot_sizeofcmds,
                           ot_object_addr,
                           ot_object_size,
                           ot_verbose,
                           ot_arm64_dc
                           )
         : 0);
      }
      catch(...)
      {
        // Stop this section on a C++ decoder error; never spin at one address.
        ot_left = 0;
        break;
      }
      
      if (parsed_bytes == 0 || parsed_bytes > ot_left)
      {
        ot_left = 0;
        break;
      }
      if (fflush(output.stream) != 0)
        [NSException raise:NSInternalInconsistencyException format:@"Cannot read disassembly output"];

      // Expand tabs without shifting past a fixed-size stack buffer.
      string line;
      size_t fieldStart = 0;
      for (size_t i = 0; i < output.size && output.buffer[i] != '\n'; ++i)
      {
        if (output.buffer[i] == '\t')
        {
          line.append(TAB_WIDTH - ((line.size() - fieldStart) % TAB_WIDTH), ' ');
          fieldStart = line.size();
        }
        else line.push_back(output.buffer[i]);
      }
      char const *symbol_name = guess_symbol(ot_addr, ot_sorted_symbols, ot_nsorted_symbols);
      if (symbol_name)
      {
        if (symbolName)
        {
          [node.details setAttributesFromRowIndex:bookmark:MVMetaDataAttributeName,symbolName,nil];
          [node.details setAttributes:MVUnderlineAttributeName,@"YES",nil];
        }
        bookmark = node.details.rowCount;
        symbolName = NSSTRING(symbol_name);
        [node.details appendRow:@"":@"":[NSString stringWithFormat:@"%@:", symbolName]:@""];
        [node.details setAttributes:MVCellColorAttributeName,[NSColor orangeColor],nil];
      }
      uint64_t fileOffset = location + (ot_addr - ot_sect_addr);
      NSRange range = NSMakeRange(fileOffset, 0);
      NSString *lastReadHex;
      [dataController read_bytes:range length:parsed_bytes lastReadHex:&lastReadHex];
      NSString *assembly = [[NSString alloc] initWithBytes:line.data() length:line.size() encoding:NSUTF8StringEncoding];
      [node.details appendRow:[NSString stringWithFormat:@"%.8llX", fileOffset]
                             :lastReadHex :assembly ?: @"(undecodable instruction)" :@""];
      
      // synchronize disassembler
      ot_left -= parsed_bytes;
      ot_sect += parsed_bytes;
      ot_addr += parsed_bytes;
      
      } // autoreleasepool: bound temporary allocations on large code sections
    } while (ot_left > 0 && (++nAsmLine % 0x1000));
  } while (ot_left > 0);

  // close last block
  if (symbolName)
  {
    [node.details setAttributesFromRowIndex:bookmark:MVMetaDataAttributeName,symbolName,nil];
    [node.details setAttributes:MVUnderlineAttributeName,@"YES",nil];
  }
  
  } // synchronized decoder state
  return node;
}

@end
