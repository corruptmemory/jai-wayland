#version 450

layout(location = 0) in vec3 v_col;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(v_col, 1.0);
}
