#ifndef DISASM_OUTPUT_H
#define DISASM_OUTPUT_H

#include <stdio.h>

/* NULL selects stdout. The caller owns the stream and must restore the previous
 * value before closing it. This isolates output, not the decoders' global state:
 * callers still have to serialize complete disassembly operations. */
FILE *disasm_set_output(FILE *stream);
FILE *disasm_output_stream(void);

/* Keep the imported cctools printers on the selected stream without redirecting
 * the process-wide stdout descriptor. Include after all system headers. */
#define printf(...) fprintf(disasm_output_stream(), __VA_ARGS__)

#endif
