/* The parts of assimp's C API `library.zig` imports models with, and stb_image (bundled with
 * assimp), which it decodes images with. */
#include <assimp/cimport.h>
#include <assimp/scene.h>
#include <assimp/material.h>
#include <assimp/postprocess.h>
#include <stb/stb_image.h>
