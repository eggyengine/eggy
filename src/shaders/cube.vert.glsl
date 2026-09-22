#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_color;
layout(location = 0) out vec3 v_color;

layout(set = 0, binding = 0) uniform Uniforms {
    mat4 mvp;
} u;

void main() {
    gl_Position = u.mvp * vec4(in_pos, 1.0);
    v_color = in_color;
}
