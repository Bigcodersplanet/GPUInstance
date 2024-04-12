﻿
#include "instance_data.hlsl"

#define unity_ObjectToWorld unity_ObjectToWorld
#define unity_WorldToObject unity_WorldToObject

float Pack2(int b1, int b2) // TODO: better packing? that is lossless in floats (this only packs integers from 0-999)
{
  return b1 * 1000.0 + (float)b2;
}
int2 Unpack2(float v)  // TODO: better packing? that is lossless in floats (this only packs integers from 0-999)
{
  float v1 = v / 1000.0;
  return int2((int)(v1), (int)(v - ((int)v1) * 1000));
}
float Pack2f(float b1, float b2) // pack 0...1 floats with up to 0.001 precision
{
  return Pack2((int)(999 * b1), (int)(999 * b2));
}
float2 Unpack2f(float v)
{
  int2 res = Unpack2(v);
  return float2(res.x * (1.0 / 999.0), res.y * (1.0 / 999.0));
}

//groupData buffer, holds where this shader instance information is in the input buffer
StructuredBuffer<int> groupDataBuffer;
//this material instance's groupID
int groupID;

StructuredBuffer<int> instanceIDBuffer; //id buffer
StructuredBuffer<instance_data> transformBuffer; //all transforms
StructuredBuffer<float4x4> object2WorldBuffer; // contains object to world matrix for every instance
StructuredBuffer<float4x4> boneMatricesBuffer;
StructuredBuffer<instance_properties> propertyBuffer;

int get_group_start(int groupID)
{
  return groupDataBuffer[groupID - 1];
}

int get_instance_id()
{
  int __temp_id;
  #ifndef SHADERGRAPH_PREVIEW
    #if UNITY_ANY_INSTANCING_ENABLED
    __temp_id = get_group_start(groupID) + unity_InstanceID;
    #else
    __temp_id = get_group_start(groupID);
    #endif
  #else
    __temp_id = get_group_start(groupID);
  #endif
  return instanceIDBuffer[__temp_id];
}

float4 get_instance_color(in int id)
{
  int c = propertyBuffer[transformBuffer[id].propertyID].color;
  float m = 0.00392156862f; // 1 / 255
  return float4(((c >> 24) & 255) * m, ((c >> 16) & 255) * m, ((c >> 8) & 255) * m, (c & 255) * m);
}

float4 get_tile_offset(in int id)
{
  float2 offset = propertyBuffer[transformBuffer[id].propertyID].offset;
  float2 tiling = propertyBuffer[transformBuffer[id].propertyID].tiling;
  return float4(tiling.x, tiling.y, offset.x, offset.y);
}

void do_instance_setup()
{
  int id;
  #ifndef SHADERGRAPH_PREVIEW
    #if UNITY_ANY_INSTANCING_ENABLED
      id = get_group_start(groupID) + unity_InstanceID;
    #else
      id = get_group_start(groupID);
    #endif
  #else
    id = get_group_start(groupID);
  #endif
   
  unity_ObjectToWorld = object2WorldBuffer[o2w_index(instanceIDBuffer[id])];
  unity_WorldToObject = object2WorldBuffer[w2o_index(instanceIDBuffer[id])];
}

void anim_vertex(in int id, in float4 texcoord1, inout float4 vertex, inout float3 normal)
{
#if Blend1
  int2 bIdx = Unpack2(texcoord1.x);
  int skel_idx = transformBuffer[id].skeletonID; // get skeleton index
  float4x4 bone_vert2world = boneMatricesBuffer[skel_idx + bIdx.x];
#elif Blend3
  int4 bIdx = int4(Unpack2(texcoord1.x), Unpack2(texcoord1.y));
  float4 bW = float4(Unpack2f(texcoord1.z), Unpack2f(texcoord1.w));
  bW = bW / (bW.x + bW.y + bW.z); // normalize sum (it may not sum to one- but could be close due to loss of precision)
  int skel_idx = transformBuffer[id].skeletonID; // get skeleton index
  float4x4 m0 = boneMatricesBuffer[skel_idx + bIdx.x];
  float4x4 m1 = boneMatricesBuffer[skel_idx + bIdx.y];
  float4x4 m2 = boneMatricesBuffer[skel_idx + bIdx.z];
  float4x4 bone_vert2world = m0 * bW.x + m1 * bW.y + m2 * bW.z;
#elif Blend4
  int4 bIdx = int4(Unpack2(texcoord1.x), Unpack2(texcoord1.y));
  float4 bW = float4(Unpack2f(texcoord1.z), Unpack2f(texcoord1.w));
  bW = bW / (bW.x + bW.y + bW.z + bW.w); // normalize sum (it may not sum to one- but could be close due to loss of precision)
  int skel_idx = transformBuffer[id].skeletonID; // get skeleton index
  float4x4 m0 = boneMatricesBuffer[skel_idx + bIdx.x];
  float4x4 m1 = boneMatricesBuffer[skel_idx + bIdx.y];
  float4x4 m2 = boneMatricesBuffer[skel_idx + bIdx.z];
  float4x4 m3 = boneMatricesBuffer[skel_idx + bIdx.w];
  float4x4 bone_vert2world = m0 * bW.x + m1 * bW.y + m2 * bW.z + m3 * bW.w;
#else
  // Blend2 is default
  int2 bIdx = Unpack2(texcoord1.x);
  float2 bW = Unpack2f(texcoord1.z);
  bW = bW / (bW.x + bW.y); // normalize sum (it may not sum to one- but could be close due to loss of precision)
  int skel_idx = transformBuffer[id].skeletonID; // get skeleton index
  float4x4 m0 = boneMatricesBuffer[skel_idx + bIdx.x];
  float4x4 m1 = boneMatricesBuffer[skel_idx + bIdx.y];
  float4x4 bone_vert2world = m0 * bW.x + m1 * bW.y;
#endif

  float3 vertex_world = mul(bone_vert2world, float4(vertex.xyz, 1)).xyz; // transform vertex to world
  float3 vertex_normal_world = mul((float3x3)bone_vert2world, normal);
  vertex = mul(unity_WorldToObject, float4(vertex_world, 1)); // transform back to model space.    TODO: ? try reduce to one gpu matrix mult (although, these are all 4x4*4x1)- okay, so with profiling it seems to be slower- no idea why
  normal = normalize(mul((float3x3)unity_WorldToObject, vertex_normal_world));
}

void setup() {
  do_instance_setup();
}

void gpuinstance_includes_float(float3 Position, out float3 Out) { Out = Position; }

void vert_float(in float4 vertex_in, in float3 normal_in : NORMAL, in float4 texcoord_in, out float4 vertex : POSITION, out float3 normal : NORMAL, out float2 uv_MainTex) {
  int id = get_instance_id();
  vertex = vertex_in;
  normal = normal_in;
  anim_vertex(id, texcoord_in, vertex, normal);
  uv_MainTex = texcoord_in.xy;
}

void surf_float(
  in UnityTexture2D _MainTex,
  in float4 _Color,
  in float2 uv_MainTex,
  out float3 Albedo)
{
  half4 c = tex2D(_MainTex, uv_MainTex) * _Color;
  Albedo = c.rgb;
}

/*#ifdef UNITY_PROCEDURAL_INSTANCING_ENABLED

struct InstanceItemData {
	float4x4 worldMatrix;
	float4x4 worldMatrixInverse;
	float4 color;
};

StructuredBuffer<InstanceItemData> _PerInstanceItemData;

// https://github.com/Unity-Technologies/Graphics/blob/master/com.unity.shadergraph/Editor/Generation/Targets/BuiltIn/ShaderLibrary/ParticlesInstancing.hlsl
void instancingItemSetup() {
	#ifndef SHADERGRAPH_PREVIEW
		unity_ObjectToWorld = mul(unity_ObjectToWorld, _PerInstanceItemData[unity_InstanceID].worldMatrix);
		unity_WorldToObject = mul(unity_WorldToObject, _PerInstanceItemData[unity_InstanceID].worldMatrixInverse);
	#endif
}

#endif

void setup() {
  instancingItemSetup();
}

void gpuinstance_includes_float(float3 Position, out float3 Out) { Out = Position; }*/