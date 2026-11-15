#language slang 2026
// A monochrome amber monitor: every colour becomes the amber of the same brightness, so emoji, image previews and
// stray program colours read as phosphor too. The theme's own amber (#ffb000) maps to itself; brighter colours lean
// toward a pale gold, the way an overdriven phosphor does. Colours are linear RGB here.

import kitty_custom_shader_types;

static const float3 PHOSPHOR = float3(1.0f, 0.434f, 0.0f);   // #ffb000 in linear RGB
static const float3 HOT = float3(1.0f, 0.75f, 0.32f);         // where the brightest whites end up
static const float STRENGTH = 1.0f;                           // 0 leaves colours alone

public float4
fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    const float3 weights = float3(0.2126f, 0.7152f, 0.0722f);
    float level = dot(color.rgb, weights) / dot(PHOSPHOR, weights);
    float3 amber = PHOSPHOR * min(level, 1.0f);
    if (level > 1.0f) amber = lerp(PHOSPHOR, HOT, min(level - 1.0f, 1.0f));
    return float4(lerp(color.rgb, amber, STRENGTH), color.a);
}
