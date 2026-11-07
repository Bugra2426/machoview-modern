#include "disasm_output.h"

static _Thread_local FILE *disasm_stream;

FILE *
disasm_set_output(FILE *stream)
{
    FILE *previous = disasm_stream;
    disasm_stream = stream;
    return previous;
}

FILE *
disasm_output_stream(void)
{
    return disasm_stream != NULL ? disasm_stream : stdout;
}
