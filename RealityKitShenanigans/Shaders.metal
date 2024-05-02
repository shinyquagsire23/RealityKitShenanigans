//
//  Shaders.metal
//  RealityKitShenanigans
//
//  Created by Max Thomas on 4/24/24.
//

#include <metal_stdlib>

#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 position [[position]];
    float4 viewPosition;
    float4 color;
    float2 texCoord;
    float planeDoProximity;
} ColorInOutPlane;

typedef struct
{
    float4 position [[position]];
    float4 color;
    float2 texCoord;
} ColorInOut;

vertex ColorInOutPlane vertexShader(Vertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               constant PlaneUniform & planeUniform [[ buffer(BufferIndexPlaneUniforms) ]])
{
    ColorInOutPlane out;
    
    float4 position = float4(in.position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * planeUniform.planeTransform * position;
    out.viewPosition = uniforms.modelViewMatrix * planeUniform.planeTransform * position;
    out.texCoord = in.texCoord;
    out.color = planeUniform.planeColor;
    out.planeDoProximity = planeUniform.planeDoProximity;

    return out;
}

fragment float4 fragmentShader(ColorInOutPlane in [[stage_in]],
                               texture2d<float> in_tex     [[ texture(TextureIndexColor) ]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]])
{
    float2 screenCoords = float2(in.position.x * (1.0/uniforms.renderWidth), fmod(in.position.y, uniforms.renderHeight) * (1.0/uniforms.renderHeight));
    screenCoords.y -= 0.5;
    screenCoords.y *= 1.5;
    screenCoords.y += 0.5;
    
    screenCoords.x -= 0.5;
    screenCoords.x *= 1.1;
    screenCoords.x += 0.5;
    
    float2 sampleCoord = screenCoords;
    constexpr sampler colorSampler(coord::normalized,
                    address::clamp_to_edge,
                    filter::linear);
    float4 texSample = in_tex.sample(colorSampler, sampleCoord);

    float4 color = in.color;
    /*if (color.a <= 0.0) {
        discard_fragment();
        return float4(0.0, 0.0, 0.0, 0.0);
    }*/
    //color.rgb = texSample.rgb;
    //color.rg = sampleCoord;
    color.a = texSample.r > 0.2 ? 1.0 : 0.0;
    return color;
}

