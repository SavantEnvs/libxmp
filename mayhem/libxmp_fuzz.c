/* libFuzzer harness over libxmp's public API: load a module (any format, including the
 * ProWizard packers and the depackers) from memory and release it. */
#include <stddef.h>
#include <stdint.h>
#include <xmp.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	xmp_context ctx;

	if (size == 0)
		return -1;
	ctx = xmp_create_context();
	if (ctx == NULL)
		return 0;
	if (xmp_load_module_from_memory(ctx, (void *)data, (long)size) == 0)
		xmp_release_module(ctx);
	xmp_free_context(ctx);
	return 0;
}
