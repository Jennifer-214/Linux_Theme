#version 300 es
// Whole-screen CRT for `desk-crt on`: dark scanlines every third pixel row. No vignette (her call, 2026-11-19: the
// darkened edges read as an amber circle). Static (no time uniform), so Hyprland keeps tracking damage and only
// redraws what changed.
precision highp float;
in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

void main() {
    vec4 color = texture(tex, v_texcoord);
    float scan = mod(gl_FragCoord.y, 3.0) < 1.0 ? 0.80 : 1.0;
    fragColor = vec4(color.rgb * scan, color.a);
}
