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
    float4 camPos;       // the camera (Earth radii, Earth-fixed), w: how much the picture is a perspective one (s)
    float4 camForward;   // where it looks, w: focal length (points)
    float4 camRight;     // the view's right, w: near plane
    float4 camUp;        // the view's up, w: far plane
    float4 orthoRight;   // the straight-down picture's right
    float4 orthoUp;      // its up
    float4 orthoToward;  // towards the viewer
    float4 sun;          // direction to the Sun (Earth-fixed), w: lighting on
    float4 relief;       // land and ocean displacement factors, hillshade strength, w: heightmap present
    float4 detail;       // the map's detail texture: first tile x, y, tiles around the world, w: present
    float4 sky;          // sky's opacity, atmosphere's opacity, cloud amount, w: city lights present
    float4 heightTexel;  // heightmap texel (1/width, 1/height), z: dark palette, w: satellite present
    float4 satDetail;    // the satellite detail texture's place: u, v of its top left, its width and height (in the world's 0 … 1)
    float4 extra;        // x: satellite detail present
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

// Where a point of the Earth lands: the orthographic and the perspective
// picture blended by s, then the flat map's place by t. `w` 1 except for a
// pure perspective picture, which the GPU divides (clipping what lies
// behind the camera).
float4 place(float3 p, float3 v, float lonRel, float latDeg, constant Uniforms &u) {
    float t = u.viewport.w, s = u.camPos.w, R = u.viewport.z;
    float3 q = p - u.camPos.xyz;
    float z = dot(q, u.camForward.xyz);
    float f = u.camForward.w;
    if (s > 0.999 && t < 0.001) {
        float nearZ = u.camRight.w, farZ = u.camUp.w;
        return float4(f * dot(q, u.camRight.xyz) / (u.viewport.x / 2), f * dot(q, u.camUp.xyz) / (u.viewport.y / 2),
                      farZ * (z - nearZ) / (farZ - nearZ), z);
    }
    float2 ortho = float2(dot(p, u.orthoRight.xyz), dot(p, u.orthoUp.xyz)) * R;
    float orthoDepth = dot(v, u.orthoToward.xyz);
    float2 persp = float2(dot(q, u.camRight.xyz), dot(q, u.camUp.xyz)) * f / max(z, 1e-4);
    float distance = length(u.camPos.xyz);
    float perspDepth = (dot(v, u.camPos.xyz) - 1) / max(distance - 1, 1e-4);
    float2 sphere = mix(ortho, persp, s);
    float depth = mix(orthoDepth, perspDepth, s);
    float W = u.center.z;
    float2 flat = float2(lonRel / 360 * W, -(mercatorY(latDeg) - u.center.w) * W);
    float2 pos = mix(sphere, flat, t);
    depth = mix(depth, 1.0, t);
    return float4(pos.x / (u.viewport.x / 2), pos.y / (u.viewport.y / 2), 0.5 - 0.45 * clamp(depth, -1.0, 1.0), 1);
}

// The ray from the camera through a point of the view (points from the
// middle, y up): its origin and direction, the orthographic camera's
// parallel rays blended into the perspective one's.
void viewRay(float2 local, constant Uniforms &u, thread float3 &origin, thread float3 &dir) {
    float s = u.camPos.w, R = u.viewport.z;
    float3 oo = (local.x / R) * u.orthoRight.xyz + (local.y / R) * u.orthoUp.xyz + 8 * u.orthoToward.xyz;
    float3 od = -u.orthoToward.xyz;
    float3 pd = normalize(u.camForward.w * u.camForward.xyz + local.x * u.camRight.xyz + local.y * u.camUp.xyz);
    origin = mix(oo, u.camPos.xyz, s);
    dir = normalize(mix(od, pd, s));
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
    MeshOut out;
    out.position = place(p, v, lonRel, latDeg, u);
    out.lonLat = in.lonLat;
    out.texY = clamp(mercatorY(latDeg), 0.0, 1.0);
    out.normal = v;
    return out;
}

// The ground's colour by day from the satellite picture (equirectangular),
// the detail texture over the whole world's where it reaches.
float3 satelliteColor(float ux, float latDeg, float2 gx, float2 gy, constant Uniforms &u,
                      texture2d<float> satBase, texture2d<float> satDetail, sampler wrap, sampler clampS) {
    float vy = (90 - latDeg) / 180;
    float2 g1 = float2(gx.x, dfdx(vy)), g2 = float2(gy.x, dfdy(vy));
    float3 c = satBase.sample(wrap, float2(fract(ux), vy), gradient2d(g1, g2)).rgb;
    if (u.extra.x > 0) {
        float du = fract(ux - u.satDetail.x);
        float dv = vy - u.satDetail.y;
        float2 rel = float2(du / u.satDetail.z, dv / u.satDetail.w);
        if (rel.x >= 0 && rel.x < 1 && rel.y >= 0 && rel.y < 1) {
            float edge = min(min(rel.x, 1 - rel.x), min(rel.y, 1 - rel.y));
            float w = smoothstep(0.0, 0.08, edge);
            float3 d = satDetail.sample(clampS, rel, gradient2d(g1 / u.satDetail.zw, g2 / u.satDetail.zw)).rgb;
            c = mix(c, d, w);
        }
    }
    return c;
}

fragment float4 globeFragment(MeshOut in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                              texture2d<float> base [[texture(0)]], texture2d<float> detail [[texture(1)]],
                              texture2d<float> heights [[texture(2)]], texture2d<float> lights [[texture(3)]],
                              texture2d<float> satBase [[texture(4)]], texture2d<float> satDetail [[texture(5)]],
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
    // The satellite picture by day; the map's own colours take over as the globe flattens
    if (u.heightTexel.w > 0) {
        float3 sat = satelliteColor(ux, latDeg, gx, gy, u, satBase, satDetail, baseSampler, detailSampler);
        rgb = mix(sat, rgb, t);
    }
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
        // Warm sunlight, cool skylight in the shadows
        float3 lit = rgb * (float3(0.30, 0.34, 0.44) + float3(1.02, 0.97, 0.88) * diffuse * 1.05);
        float3 night = rgb * (u.heightTexel.z > 0.5 ? float3(0.10, 0.12, 0.20) : float3(0.05, 0.07, 0.14));
        if (u.sky.w > 0) {
            float ly = (90 - latDeg) / 180;
            float city = lights.sample(baseSampler, float2(fract(ux), ly), gradient2d(float2(gx.x, dfdx(ly)), float2(gy.x, dfdy(ly)))).r;
            night += city * float3(1.0, 0.78, 0.48);
        }
        // The sea glints where it mirrors the Sun towards the camera; the
        // heightmap's cells are 14 km, so the water fades out over the last
        // tens of metres above the sea floor instead of ending at a cell's edge
        float water = u.relief.w > 0 ? 1 - smoothstep(-0.04, 0.005, h) : 0;
        if (water > 0) {
            float3 p = v;
            float3 toEye = normalize(mix(u.orthoToward.xyz, u.camPos.xyz - p, u.camPos.w));
            float3 mirrored = reflect(-L, v);
            float glint = pow(saturate(dot(mirrored, toEye)), 90.0) * 0.9 + pow(saturate(dot(mirrored, toEye)), 12.0) * 0.12;
            lit += float3(1.0, 0.9, 0.75) * glint * day * water;
        }
        // A warm band along the terminator
        float dusk = exp(-geo * geo * 600) * 0.10;
        float3 shaded = mix(night, lit, day) + float3(1.0, 0.5, 0.25) * dusk * day * rgb;
        rgb = mix(rgb, shaded, fade);
    } else if (u.relief.w > 0 && u.relief.z > 0) {
        // Map-style hillshade, light from the north-west
        float3 Lm = normalize(-east + north + 1.4 * v);
        float ratio = dot(nrm, Lm) / max(dot(v, Lm), 0.1);
        rgb *= mix(1.0, clamp(1 + (ratio - 1) * 0.9, 0.55, 1.3), fade);
    }
    return float4(rgb, 1);
}

// MARK: Clouds

struct CloudOut {
    float4 position [[position]];
    float2 lonLat;
    float3 normal;
};

vertex CloudOut cloudVertex(MeshIn in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float lonRel = in.lonLat.x, latDeg = in.lonLat.y;
    float lonDeg = u.center.y * 180 / PI + lonRel;
    float3 v = unitVector(latDeg * PI / 180, lonDeg * PI / 180);
    CloudOut out;
    out.position = place(v * 1.006, v, lonRel, latDeg, u);
    out.lonLat = in.lonLat;
    out.normal = v;
    return out;
}

fragment float4 cloudFragment(CloudOut in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                              texture2d<float> clouds [[texture(0)]], sampler wrap [[sampler(0)]]) {
    float latDeg = in.lonLat.y;
    float lonDeg = u.center.y * 180 / PI + in.lonLat.x;
    float ux = (lonDeg + 180) / 360, vy = (90 - latDeg) / 180;
    float2 uv = float2(ux, vy);
    float c = clouds.sample(wrap, float2(fract(ux), vy), gradient2d(dfdx(uv), dfdy(uv))).r;
    // The picture's faint ground and haze left out: only real clouds
    float a = smoothstep(0.22, 0.85, c) * u.sky.z * (1 - u.viewport.w);
    float3 v = normalize(in.normal);
    // Seen edge-on at the limb the cloud shell would stand out as a thin line above the ground
    float3 toEye = normalize(mix(u.orthoToward.xyz, u.camPos.xyz - v * 1.006, u.camPos.w));
    a *= smoothstep(0.02, 0.12, dot(v, toEye));
    if (a <= 0.001) discard_fragment();
    float light = 0.92;
    if (u.sun.w > 0.5) {
        float geo = dot(v, u.sun.xyz);
        light = mix(0.035, 1.0, smoothstep(-0.12, 0.12, geo)) * (0.55 + 0.45 * saturate(geo + 0.3));
    }
    float3 col = float3(1.0, 0.99, 0.97) * light;
    return float4(col * a, a);
}

// MARK: Atmosphere and Sun

struct ScreenOut {
    float4 position [[position]];
    float2 local;   // points from the view's middle, y up
};

vertex ScreenOut screenVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(1)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    ScreenOut out;
    out.position = float4(corner, 0.999, 1);
    out.local = corner * u.viewport.xy / 2;
    return out;
}

// A thin shell of air: Rayleigh-like blue on the day side, a warm band
// where the Sun sets, light scattered forwards towards the Sun; over the
// ground a haze growing towards the rim. Then the Sun itself, a disc with
// its glare, hidden by the Earth but for the glare's outer part.
fragment float4 atmosphereFragment(ScreenOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float3 o, d;
    viewRay(in.local, u, o, d);
    // The ground's haze over a sphere a little below sea level: the sea is drawn lowered by its depth
    // (`relief.y`), and rays between it and the sea level would show haze with nothing behind it
    float b = dot(o, d), c = dot(o, o) - 0.997 * 0.997;
    float disc = b * b - c;
    bool hit = disc > 0 && -b - sqrt(max(disc, 0.0)) > 0;
    bool lit = u.sun.w > 0.5;
    float3 L = u.sun.xyz;
    float3 blue = float3(0.32, 0.58, 1.0), warm = float3(1.0, 0.48, 0.20);
    float3 col = float3(0);
    float alpha = 0;
    float strength = u.sky.y;
    if (!hit) {
        float tc = max(-b, 0.0);
        float3 closest = o + tc * d;
        float altitude = length(closest) - 1;
        float rim = exp(-max(altitude, 0.0) / 0.028) * (1 - smoothstep(0.0, 0.35, altitude));   // smoothstep needs edge0 < edge1 in Metal
        float3 at = normalize(closest);
        if (lit) {
            float sunDot = dot(at, L);
            float day = smoothstep(-0.28, 0.25, sunDot);
            // The warm band of sunrise and sunset shows looking towards the Sun
            float towards = saturate(dot(d, L));
            float terminator = exp(-sunDot * sunDot / 0.012) * smoothstep(0.0, 0.7, towards);
            float forward = pow(towards, 6.0);
            col = blue * (0.35 + 0.65 * day) * (1 + forward * 1.6) + warm * terminator * 0.9;
            alpha = rim * (0.25 + 0.75 * max(day, terminator * 0.8));
        } else {
            col = blue;
            alpha = rim * 0.8;
        }
    } else {
        float3 p = o + (-b - sqrt(disc)) * d;
        float mu = saturate(dot(-d, p));
        float haze = pow(1 - mu, 3.0) * 0.6;
        if (lit) {
            float sunDot = dot(p, L);
            float day = smoothstep(-0.15, 0.25, sunDot);
            float terminator = exp(-sunDot * sunDot / 0.01);
            col = blue * day + warm * terminator * 0.6;
            alpha = haze * max(day, terminator * 0.5);
        } else {
            col = blue;
            alpha = haze * 0.55;
        }
    }
    alpha *= strength;
    float3 premultiplied = col * alpha;
    // The Sun (only through the perspective camera: far out it is behind the viewer)
    if (lit && u.camPos.w > 0.001) {
        float sd = saturate(dot(d, L));
        float seen = hit ? 0.0 : 1.0;
        float sunDisc = smoothstep(0.99995, 0.99998, sd) * seen * 6.0;
        float glare = pow(sd, 6000.0) * 1.5 * seen + pow(sd, 400.0) * 0.30 * mix(0.4, 1.0, seen) + pow(sd, 24.0) * 0.06;
        premultiplied += float3(1.0, 0.93, 0.80) * (sunDisc + glare) * u.camPos.w * strength;
    }
    return float4(premultiplied, alpha);
}

// MARK: Sky

// The star map (equirectangular in right ascension and declination, 0h in
// the middle, right ascension increasing to the left) seen along each
// pixel's ray: its direction turned from the Earth-fixed frame back to J2000.
fragment float4 skyFragment(ScreenOut in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                            texture2d<float> sky [[texture(0)]], sampler s [[sampler(0)]]) {
    // Far out a 90° camera along the view; tilted the perspective camera's own rays
    float skyFocal = min(u.viewport.x, u.viewport.y) / 2;
    float3 od = normalize(in.local.x * u.orthoRight.xyz + in.local.y * u.orthoUp.xyz - skyFocal * u.orthoToward.xyz);
    float3 pd = normalize(u.camForward.w * u.camForward.xyz + in.local.x * u.camRight.xyz + in.local.y * u.camUp.xyz);
    float3 d = normalize(mix(od, pd, u.camPos.w));
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
    // A touch deeper blue in the dark
    color.rgb = color.rgb * 0.8 + float3(0.0, 0.004, 0.012);
    return float4(color.rgb * a, a);
}
"""#
}
