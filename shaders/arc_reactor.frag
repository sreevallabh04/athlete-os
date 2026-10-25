// Athlete OS — reactor core glow for the JarvisOrb / hero ring.
// White-hot core, accent halo, slow rotating rays, a breathing ring.
// Outputs premultiplied alpha so it composites over anything.
#version 460 core
#include <flutter/runtime_effect.glsl>

precision mediump float;

uniform vec2 uSize;
uniform float uTime;
uniform float uEnergy; // 0..1: idle ~0.25, speaking/listening up to 1
uniform vec4 uColor;

out vec4 fragColor;

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 c = uSize * 0.5;
  float r = min(uSize.x, uSize.y) * 0.5;
  vec2 p = (frag - c) / r;
  float d = length(p);
  float a = atan(p.y, p.x);

  float e = clamp(uEnergy, 0.0, 1.0);
  float core = exp(-d * d * (11.0 - 4.0 * e));
  float halo = exp(-d * 3.1) * (0.30 + 0.35 * e);
  float rays = pow(0.5 + 0.5 * sin(a * 12.0 + uTime * 1.3), 7.0)
             * smoothstep(0.95, 0.2, d) * (0.10 + 0.14 * e);
  float rays2 = pow(0.5 + 0.5 * sin(a * 7.0 - uTime * 0.9), 9.0)
              * smoothstep(0.9, 0.3, d) * 0.08;
  float ringR = 0.64 + 0.035 * sin(uTime * 2.1) * (0.4 + e);
  float ring = smoothstep(0.035, 0.0, abs(d - ringR)) * (0.35 + 0.3 * e);
  float flicker = 0.95 + 0.05 * sin(uTime * 13.0 + sin(uTime * 3.1));

  float glow = (halo + rays + rays2 + ring) * flicker;
  vec3 col = uColor.rgb * glow + mix(uColor.rgb, vec3(1.0), 0.75) * core;
  float alpha = clamp(max(core, glow), 0.0, 1.0) * smoothstep(1.0, 0.82, d);
  fragColor = vec4(col * alpha, alpha);
}
