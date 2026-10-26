// Athlete OS — holographic HUD background.
// Warm charcoal canvas: slow domain-warped ember haze + faint hex grid + sparse twinkles + scanlines,
// vignette and film grain. Deliberately low intensity: it should be felt,
// not seen. Cost: 4-octave value-noise fbm x3, ~120 ALU ops per pixel.
#version 460 core
#include <flutter/runtime_effect.glsl>

precision mediump float;

uniform vec2 uSize;       // logical size of the painted rect
uniform float uTime;      // seconds
uniform float uIntensity; // 0..1
uniform vec4 uAccent;     // accent rgb
uniform vec4 uTop;        // canvas top rgb
uniform vec4 uBottom;     // canvas bottom rgb

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
             u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = p * 2.03 + vec2(1.7, 9.2);
    a *= 0.5;
  }
  return v;
}

float hexDist(vec2 p) {
  p = abs(p);
  return max(dot(p, vec2(0.5, 0.8660254)), p.x);
}

vec4 hexCoords(vec2 uv) {
  vec2 r = vec2(1.0, 1.7320508);
  vec2 h = r * 0.5;
  vec2 a = mod(uv, r) - h;
  vec2 b = mod(uv - h, r) - h;
  vec2 gv = dot(a, a) < dot(b, b) ? a : b;
  return vec4(gv, uv - gv);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize;
  float aspect = uSize.x / uSize.y;
  vec3 col = mix(uTop.rgb, uBottom.rgb, uv.y);
  vec3 accent = uAccent.rgb;

  // Domain-warped nebula drifting very slowly.
  vec2 p = vec2(uv.x * aspect, uv.y) * 2.2;
  float t = uTime * 0.035;
  vec2 q = vec2(fbm(p + vec2(0.0, t)), fbm(p + vec2(5.2, 1.3) - t));
  float n = fbm(p + 1.6 * q + vec2(t * 0.6, -t * 0.4));
  float neb = smoothstep(0.38, 0.95, n);
  // Warm ember haze: a faint accent (red) nebula with a gold undertone.
  vec3 deep = vec3(0.55, 0.36, 0.10);
  col += accent * neb * 0.05 * uIntensity;
  col += deep * smoothstep(0.45, 1.0, q.x) * 0.035 * uIntensity;

  // Reactor light spilling from above the top edge.
  float top = smoothstep(1.05, 0.0, length((uv - vec2(0.5, -0.08)) * vec2(1.0, 1.5)));
  col += accent * top * 0.06 * uIntensity;

  // Hex grid, fading out towards the bottom, cells breathing out of phase.
  vec4 hc = hexCoords(frag / 44.0);
  float edge = smoothstep(0.46, 0.5, hexDist(hc.xy));
  float mask = smoothstep(1.0, 0.0, uv.y) * 0.6 + 0.12;
  float breathe = 0.55 + 0.45 * sin(uTime * 0.5 + hash(hc.zw) * 6.2831);
  col += mix(accent, deep, 0.35) * edge * 0.03 * mask * breathe * uIntensity;

  // Sparse twinkles.
  vec2 cell = floor(frag / 26.0);
  float h = hash(cell);
  if (h > 0.986) {
    vec2 c = (cell + vec2(hash(cell + 1.3), hash(cell + 7.1))) * 26.0;
    float d = length(frag - c);
    float tw = 0.5 + 0.5 * sin(uTime * (0.7 + h * 1.8) + h * 40.0);
    col += mix(accent, vec3(1.0, 0.85, 0.55), 0.6) * smoothstep(1.6, 0.0, d) * 0.3 * tw * uIntensity;
  }

  // Scanlines + vignette + grain.
  col *= 0.988 + 0.012 * sin(frag.y * 1.5707963);
  float vig = smoothstep(1.25, 0.3, length(uv - vec2(0.5, 0.42)));
  col *= mix(0.7, 1.0, vig);
  col += (hash(frag + fract(uTime * 0.37)) - 0.5) * 0.010;

  fragColor = vec4(col, 1.0);
}
