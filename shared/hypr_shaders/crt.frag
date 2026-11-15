#version 300 es
// Whole-screen CRT for `desk-crt on`: dark scanlines every third pixel row and a soft vignette. Static (no time
// uniform), so Hyprland keeps tracking damage and only redraws what changed.
precision highp float;
in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

void main() {
    vec4 color = texture(tex, v_texcoord);
    float scan = mod(gl_FragCoord.y, 3.0) < 1.0 ? 0.80 : 1.0;
    vec2 d = v_texcoord - 0.5;
    float vignette = 1.0 - dot(d, d) * 0.6;
    fragColor = vec4(color.rgb * scan * vignette, color.a);
}
