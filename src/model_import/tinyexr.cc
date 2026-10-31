/* tinyexr's code, for `eggy_assimp` to decode OpenEXR images with. It inflates through the zlib
 * bundled with assimp rather than a copy of miniz of its own, and reads on one thread. */
#define TINYEXR_USE_MINIZ 0
#define TINYEXR_USE_THREAD 0
#define TINYEXR_USE_OPENMP 0
#include <zlib.h>
#define TINYEXR_IMPLEMENTATION
#include "tinyexr.h"
