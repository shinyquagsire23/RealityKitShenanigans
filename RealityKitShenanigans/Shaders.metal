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
} ColorInOutPlane;

typedef struct
{
    float4 position [[position]];
    float4 color;
    float2 texCoord;
} ColorInOut;

vertex ColorInOutPlane vertexShader(Vertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOutPlane out;
    
    float4 position = float4(in.position, 1.0);
    if (position.x < 1.0) {
        position.x *= uniforms.tangents[0];
    }
    else {
        position.x *= uniforms.tangents[1];
    }
    if (position.y < 1.0) {
        position.y *= uniforms.tangents[3];
    }
    else {
        position.y *= uniforms.tangents[2];
    }

    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    out.viewPosition = uniforms.modelViewMatrix* position;
    out.texCoord = in.texCoord;
    out.color = float4(0.0, uniforms.which == 0 ? 1.0 : 0.0, uniforms.which == 1 ? 1.0 : 0.0, 1.0);

    return out;
}

fragment float4 fragmentShader(ColorInOutPlane in [[stage_in]],
                               texture2d<half> colorMap     [[ texture(TextureIndexColor) ]])
{
    float4 color = in.color;
    /*if (in.planeDoProximity >= 0.5) {
        float cameraDistance = ((-in.viewPosition.z / in.viewPosition.w));
        float cameraX = (in.viewPosition.x);
        float cameraY = (in.viewPosition.y);
        float distFromCenterOfCamera = clamp((2.0 - sqrt(cameraX*cameraX+cameraY*cameraY)) / 2.0, 0.0, 0.9);
        cameraDistance = clamp((1.5 - sqrt(cameraDistance))/1.5, 0.0, 1.0);
        
        color *= pow(distFromCenterOfCamera * cameraDistance, 2.2);
        color.a = in.color.a;
    }*/
    
    //color.a = in.viewPosition.x;
    
    if (color.a <= 0.0) {
        discard_fragment();
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    return color;
}

