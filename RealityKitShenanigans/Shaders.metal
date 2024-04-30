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
                               texture2d<float> in_tex     [[ texture(TextureIndexColor) ]])
{
    float2 screenCoords = float2(in.position.x * (1.0/2048.0), fmod(in.position.y, 2048.0) * (1.0/2048.0));
    screenCoords.y -= 0.5;
    screenCoords.y *= 1.5;
    screenCoords.y += 0.5;
    
    screenCoords.x -= 0.5;
    screenCoords.x *= 1.1;
    screenCoords.x += 0.5;
    
    /*if (screenCoords.x < 0.0 && screenCoords.y <= 1.0/3.0) {
        screenCoords = float2(0,0);
    }
    else if (screenCoords.x < 0.0 && screenCoords.y > 1.0/3.0 && screenCoords.y <= 2.0/3.0) {
        screenCoords = float2(0,0.5);
    }
    else if (screenCoords.x < 0.0 && screenCoords.y > 2.0/3.0 && screenCoords.y <= 3.0/3.0) {
        screenCoords = float2(0,1.0);
    }
    else if (screenCoords.x > 1.0 && screenCoords.y <= 1.0/3.0) {
        screenCoords = float2(1,0);
    }
    else if (screenCoords.x > 1.0 && screenCoords.y > 1.0/3.0 && screenCoords.y <= 2.0/3.0) {
        screenCoords = float2(1,0.5);
    }
    else if (screenCoords.x > 1.0 && screenCoords.y > 2.0/3.0 && screenCoords.y <= 3.0/3.0) {
        screenCoords = float2(1,1.0);
    }
    else if (screenCoords.y < 0.0 && screenCoords.x <= 1.0/3.0) {
        screenCoords = float2(0,0);
    }
    else if (screenCoords.y < 0.0 && screenCoords.x > 1.0/3.0 && screenCoords.y <= 2.0/3.0) {
        screenCoords = float2(0.5,0);
    }
    else if (screenCoords.y < 0.0 && screenCoords.x > 2.0/3.0 && screenCoords.y <= 3.0/3.0) {
        screenCoords = float2(1.0,0);
    }
    else if (screenCoords.y > 1.0 && screenCoords.x <= 1.0/3.0) {
        screenCoords = float2(0, 1.0);
    }
    else if (screenCoords.y > 1.0 && screenCoords.x > 1.0/3.0 && screenCoords.y <= 2.0/3.0) {
        screenCoords = float2(0.5, 1.0);
    }
    else if (screenCoords.y > 1.0 && screenCoords.x > 2.0/3.0 && screenCoords.y <= 3.0/3.0) {
        screenCoords = float2(1.0, 1.0);
    }*/
    
    float2 sampleCoord = screenCoords;
    //float2 sampleCoord = in.texCoord;
    //sampleCoord.y *= -1.0;
    constexpr sampler colorSampler(coord::normalized,
                    address::clamp_to_edge,
                    filter::linear);
    float4 texSample = in_tex.sample(colorSampler, sampleCoord);
    
    /*if (screenCoords.x < 0.0 || screenCoords.y < 0.0 || screenCoords.x > 1.0 || screenCoords.y > 1.0) {
        float sample1 = in_tex.sample(colorSampler, float2(0,0)).r * 2.0;
        float sample2 = in_tex.sample(colorSampler, float2(0,1)).r * 2.0;
        float sample3 = in_tex.sample(colorSampler, float2(1,0)).r * 2.0;
        float sample4 = in_tex.sample(colorSampler, float2(1,1)).r * 2.0;
        float megaSample = (sample1 + sample2 + sample3 + sample4) / 4.0;
        /*if (sample1 < 0.5) {
            texSample.rgb = 0.0;
        }
        else {
            texSample.rgb = 1.0;
        }* /
        texSample.rgb = megaSample * 4.0;
    }*/

    float4 color = in.color;
    if (in.planeDoProximity >= 0.5) {
        float cameraDistance = ((-in.viewPosition.z / in.viewPosition.w));
        float cameraX = (in.viewPosition.x);
        float cameraY = (in.viewPosition.y);
        float distFromCenterOfCamera = clamp((2.0 - sqrt(cameraX*cameraX+cameraY*cameraY)) / 2.0, 0.0, 0.9);
        cameraDistance = clamp((1.5 - sqrt(cameraDistance))/1.5, 0.0, 1.0);
        
        //color *= pow(distFromCenterOfCamera * cameraDistance, 2.2);
        color.a = in.color.a;
    }
    
    if (color.a <= 0.0) {
        discard_fragment();
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    //color.rgb = texSample.rgb;
    //color.rg = sampleCoord;
    color.a = texSample.r > 0.2 ? 1.0 : 0.0;
    return color;
}

