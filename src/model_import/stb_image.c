/* stb_image's code, from assimp's copy of it, for `eggy_assimp` to decode images with. assimp
 * builds a PNG-only copy of its own; two of stb_image's functions are global even then, so ours
 * are renamed. */
#define stbi_set_unpremultiply_on_load_thread eggy_stbi_set_unpremultiply_on_load_thread
#define stbi_convert_iphone_png_to_rgb_thread eggy_stbi_convert_iphone_png_to_rgb_thread
#define STB_IMAGE_IMPLEMENTATION
#include <stb/stb_image.h>
