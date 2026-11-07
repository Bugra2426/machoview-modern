#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../disasm_output.h"

static void *exercise(void *arg)
{
    char *buffer = NULL, *nested_buffer = NULL;
    size_t size = 0, nested_size = 0, i;
    char value = (char)(uintptr_t)arg;
    FILE *stream = open_memstream(&buffer, &size);
    FILE *nested = open_memstream(&nested_buffer, &nested_size);
    FILE *previous;
    assert(stream != NULL && nested != NULL);
    assert(disasm_output_stream() == stdout);
    previous = disasm_set_output(stream);
    assert(previous == NULL);
    /* Much larger than a pipe: no process stdout hijack or pipe deadlock. */
    for(i = 0; i < 1024 * 1024; i++)
        printf("%c", value);
    assert(disasm_set_output(nested) == stream);
    printf("nested");
    assert(disasm_set_output(stream) == nested);
    assert(fclose(nested) == 0);
    assert(nested_size == 6 && strcmp(nested_buffer, "nested") == 0);
    free(nested_buffer);
    assert(fflush(stream) == 0);
    assert(size == 1024 * 1024);
    for(i = 0; i < size; i++)
        assert(buffer[i] == value);
    /* SectionContents reuses a memory stream for successive instructions. The
     * published size, not strlen(buffer), bounds the newly printed instruction. */
    assert(fseek(stream, 0, SEEK_SET) == 0);
    printf("short");
    assert(fflush(stream) == 0);
    assert(size == 5 && memcmp(buffer, "short", size) == 0);
    assert(disasm_set_output(previous) == stream);
    assert(disasm_output_stream() == stdout);
    assert(fclose(stream) == 0);
    assert(size == 5);
    free(buffer);
    return NULL;
}

int main(void)
{
    pthread_t threads[4];
    unsigned i;
    for(i = 0; i < 4; i++)
        assert(pthread_create(&threads[i], NULL, exercise,
                              (void *)(uintptr_t)('a' + i)) == 0);
    for(i = 0; i < 4; i++)
        assert(pthread_join(threads[i], NULL) == 0);
    assert(disasm_output_stream() == stdout);
    puts("thread-local output");
    return 0;
}
