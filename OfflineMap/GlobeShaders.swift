/// The globe's Metal shaders, compiled at run time (`MTLDevice.makeLibrary(source:)`),
/// so neither SwiftPM nor the Xcode project needs a Metal build step.
/// `GlobeUniforms` in GlobeRenderer.swift is the same struct on the CPU side.
enum GlobeShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 viewport;     // view width, height (points), sphere radius (points), flatness t
    float4 center;       // centre latitude, longitude (radians), world width (points), centre's Mercator y
    float4 basisE;       // screen right (east at the centre), Earth-fixed
    float4 basisN;       // screen up (north at the centre)
    float4 basisU;       // towards the viewer
    float4 sun;          // direction to the Sun (Earth-fixed), w: lighting on
    float4 relief;       // land and ocean displacement factors, hillshade strength, w: heightmap present
    float4 detail;       // detail texture's first tile x, y, tiles around the world, w: present
    float4 sky;          // sky's opacity, sky focal length (points), glow opacity, w: city lights present
    float4 heightTexel;  // heightmap texel (1/width, 1/height), z: dark palette
    float4 northColor;   // beyond the Web Mercator square: the Arctic sea
    float4 southColor;   // and Antarctica's ice
    float4x4 starMatrix; // J2000 directions to Earth-fixed ones (the sky)
};

constant float PI = 3.14159265358979;
constant float MAX_LAT = 85.0511287798;

float3 unitVector(float lat, float lon) {
    return float3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat));
}

float mercatorY(float latDeg) {
    float lat = clamp(latDeg, -MAX_LAT, MAX_LAT) * PI / 180;
    return (1 - log(tan(lat) + 1 / cos(lat)) / PI) / 2;
}

float heightKm(texture2d<float> heights, sampler s, float latDeg, float lonDeg) {
    float2 uv = float2(fract((lonDeg + 180) / 360), (90 - latDeg) / 180);
    return heights.sample(s, uv, level(0)).r;
}

// MARK: Globe

struct MeshIn {
    float2 lonLat [[attribute(0)]];   // longitude from the centre, latitude (degrees)
};

struct MeshOut {
    float4 position [[position]];
    float2 lonLat;
    float texY;
    float3 normal;
};

vertex MeshOut globeVertex(MeshIn in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                           texture2d<float> heights [[texture(0)]], sampler hs [[sampler(0)]]) {
    float t = u.viewport.w;
    float lonRel = in.lonLat.x, latDeg = in.lonLat.y;
    float lonDeg = u.center.y * 180 / PI + lonRel;
    float3 v = unitVector(latDeg * PI / 180, lonDeg * PI / 180);
    float h = u.relief.w > 0 ? heightKm(heights, hs, latDeg, lonDeg) : 0;
    float k = h >= 0 ? u.relief.x : u.relief.y;
    float3 p = v * (1 + h * k / 6371.0 * (1 - t));
    float R = u.viewport.z;
    float2 sphere = float2(dot(p, u.basisE.xyz), dot(p, u.basisN.xyz)) * R;
    float W = u.center.z;
    float2 flat = float2(lonRel / 360 * W, -(mercatorY(latDeg) - u.center.w) * W);
    float2 pos = mix(sphere, flat, t);
    float depth = mix(dot(v, u.basisU.xyz), 1.0, t);
    MeshOut out;
    out.position = float4(pos.x / (u.viewport.x / 2), pos.y / (u.viewport.y / 2), 0.5 - 0.45 * depth, 1);
    out.lonLat = in.lonLat;
    out.texY = clamp(mercatorY(latDeg), 0.0, 1.0);
    out.normal = v;
    return out;
}

fragment float4 globeFragment(MeshOut in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                              texture2d<float> base [[texture(0)]], texture2d<float> detail [[texture(1)]],
                              texture2d<float> heights [[texture(2)]], texture2d<float> lights [[texture(3)]],
                              sampler baseSampler [[sampler(0)]], sampler detailSampler [[sampler(1)]],
                              sampler hs [[sampler(2)]]) {
    float t = u.viewport.w;
    float latDeg = in.lonLat.y;
    float lonDeg = u.center.y * 180 / PI + in.lonLat.x;
    float ux = (lonDeg + 180) / 360;   // unwrapped: continuous across the antimeridian
    float2 uvU = float2(ux, in.texY);
    float2 gx = dfdx(uvU), gy = dfdy(uvU);
    float4 color = base.sample(baseSampler, float2(fract(ux), in.texY), gradient2d(gx, gy));
    if (u.detail.w > 0) {
        float n = u.detail.z;
        float span = min(8.0, n);
        float rx = ux * n - u.detail.x;
        rx -= floor(rx / n) * n;
        float ry = in.texY * n - u.detail.y;
        if (rx < span && ry >= 0 && ry < span) {
            float edge = min(min(rx, span - rx), min(ry, span - ry));
            float w = smoothstep(0.0, 0.75, edge);
            float4 dc = detail.sample(detailSampler, float2(rx, ry) / span, gradient2d(gx * n / span, gy * n / span));
            color = mix(color, dc, w);
        }
    }
    // Beyond ±85.05° the tiles end: the palette's sea in the north, ice in the south
    float polar = smoothstep(84.0, MAX_LAT, abs(latDeg));
    color.rgb = mix(color.rgb, latDeg > 0 ? u.northColor.rgb : u.southColor.rgb, polar);
    float3 rgb = color.rgb;
    float fade = 1 - t;
    float3 v = normalize(in.normal);
    float lat = latDeg * PI / 180, lon = lonDeg * PI / 180;
    float3 east = float3(-sin(lon), cos(lon), 0);
    float3 north = float3(-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat));
    float3 nrm = v;
    float h = 0;
    if (u.relief.w > 0) {
        // The slope over the same distance east and north (a texel north–south)
        float dLat = u.heightTexel.y * 180;
        float dLon = min(dLat / max(cos(lat), 0.02), 30.0);
        h = heightKm(heights, hs, latDeg, lonDeg);
        float he = heightKm(heights, hs, latDeg, lonDeg + dLon), hw = heightKm(heights, hs, latDeg, lonDeg - dLon);
        float hn = heightKm(heights, hs, latDeg + dLat, lonDeg), hsouth = heightKm(heights, hs, latDeg - dLat, lonDeg);
        float gEast = (he - hw) / (2 * dLon * 111.2 * max(cos(lat), 0.02));
        float gNorth = (hn - hsouth) / (2 * dLat * 111.2);
        nrm = normalize(v - u.relief.z * (gEast * east + gNorth * north));
        // Deep water darker
        if (h < 0) rgb *= mix(1.0, 0.78, saturate(-h / 6.0) * fade * saturate(u.relief.z / 20));
    }
    if (u.sun.w > 0.5) {
        float3 L = u.sun.xyz;
        float geo = dot(v, L);
        float day = smoothstep(-0.10, 0.06, geo);
        float diffuse = saturate(dot(nrm, L));
        float3 lit = rgb * (u.heightTexel.z > 0.5 ? 0.45 + 0.95 * diffuse : 0.40 + 0.70 * diffuse);
        float3 night = rgb * (u.heightTexel.z > 0.5 ? float3(0.16, 0.17, 0.22) : float3(0.10, 0.11, 0.16));
        if (u.sky.w > 0) {
            float ly = (90 - latDeg) / 180;
            float city = lights.sample(baseSampler, float2(fract(ux), ly), gradient2d(float2(gx.x, dfdx(ly)), float2(gy.x, dfdy(ly)))).r;
            night += city * float3(1.0, 0.80, 0.52);
        }
        // A warm rim along the terminator
        float dusk = exp(-geo * geo * 900) * 0.05;
        float3 shaded = mix(night, lit, day) + float3(1.0, 0.55, 0.3) * dusk * day;
        rgb = mix(rgb, shaded, fade);
    } else if (u.relief.w > 0 && u.relief.z > 0) {
        // Map-style hillshade, light from the north-west
        float3 Lm = normalize(-east + north + 1.4 * v);
        float ratio = dot(nrm, Lm) / max(dot(v, Lm), 0.1);
        rgb *= mix(1.0, clamp(1 + (ratio - 1) * 0.9, 0.55, 1.3), fade);
    }
    return float4(rgb, 1);
}

// MARK: Atmosphere

struct GlowOut {
    float4 position [[position]];
    float2 local;   // in sphere radii, y up
};

vertex GlowOut glowVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(1)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0) * 1.3;
    float R = u.viewport.z;
    GlowOut out;
    out.position = float4(corner * R / (u.viewport.xy / 2), 0.99, 1);
    out.local = corner;
    return out;
}

fragment float4 glowFragment(GlowOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float r = length(in.local);
    if (r > 1.3) discard_fragment();
    // From just inside the rim (the globe covers it; the sea floor sinks below r = 1)
    float a = exp(-max(r - 1, 0.0) * 16) * smoothstep(1.3, 1.15, r) * smoothstep(0.9, 0.97, r);
    float3 limb = normalize(in.local.x * u.basisE.xyz + in.local.y * u.basisN.xyz);
    float day = u.sun.w > 0.5 ? mix(0.12, 1.0, smoothstep(-0.25, 0.25, dot(limb, u.sun.xyz))) : 0.75;
    a *= day * u.sky.z;
    return float4(float3(0.36, 0.62, 1.0) * a, a);
}

// MARK: Sky

struct SkyOut {
    float4 position [[position]];
    float2 local;   // points from the view's middle, y up
};

vertex SkyOut skyVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(1)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    SkyOut out;
    out.position = float4(corner, 0.999, 1);
    out.local = corner * u.viewport.xy / 2;
    return out;
}

// The star map (equirectangular in right ascension and declination, 0h in
// the middle, right ascension increasing to the left) seen along the view:
// each pixel's direction turned from the Earth-fixed frame back to J2000.
fragment float4 skyFragment(SkyOut in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                            texture2d<float> sky [[texture(0)]], sampler s [[sampler(0)]]) {
    float3 d = normalize(in.local.x * u.basisE.xyz + in.local.y * u.basisN.xyz - u.sky.y * u.basisU.xyz);
    float3 c = (transpose(u.starMatrix) * float4(d, 0)).xyz;
    float ra = atan2(c.y, c.x) / (2 * PI);          // turns, -0.5 ... 0.5
    float dec = asin(clamp(c.z, -1.0, 1.0)) / PI;   // -0.5 ... 0.5
    float2 uv = float2(fract(0.5 - ra), 0.5 - dec);
    // The gradient of whichever of two wrappings is continuous here (no seam at 0h / 12h)
    float2 uvShifted = float2(fract(1.0 - ra), uv.y);
    float2 gx = dfdx(uv), gy = dfdy(uv), gxs = dfdx(uvShifted), gys = dfdy(uvShifted);
    if (abs(gxs.x) < abs(gx.x)) gx.x = gxs.x;
    if (abs(gys.x) < abs(gy.x)) gy.x = gys.x;
    float4 color = sky.sample(s, uv, gradient2d(gx, gy));
    float a = u.sky.x;
    color.rgb *= 0.8;
    return float4(color.rgb * a, a);
}
"""#
}
