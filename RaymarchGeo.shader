// This shader uses techniques from many sources, specifically https://bgolus.medium.com/rendering-a-sphere-on-a-quad-13c92025570c#38ad
// as well as http://jamie-wong.com/2016/07/15/ray-marching-signed-distance-functions/ and SDFs from https://www.iquilezles.org/www/articles/menger/menger.htm

Shader "Raymarched Geometry"
{
	Properties
	{
		_DiffuseColor("Diffuse", Color) = (0.2, 0.2, 1.0, 0.0)
		_SpecularColor("Specular", Color) = (0.0, 0.0, 0.0, 1.0)
		_Smoothness("Smoothness", Range(0,1)) = 0.9
		_Emission("Emission", Color) = (0.0, 0.0, 0.0, 0.0)
	}

	SubShader
	{
		Tags { "RenderType" = "AlphaTest" "DisableBatching" = "True" }
		LOD 100

		CGINCLUDE
			static const int MAX_MARCHING_STEPS = 255;
			static float MIN_DIST = 0.0;
			static float MAX_DIST = 100.0;
			static const float EPSILON = 0.0001;
			static const float3 WORLD_UP = float3(0.0f, 1.0f, 0.0f); 

			#include "UnityCG.cginc"

			// GLSL style Modulo
			#define mod(x, y) (x - y * floor(x / y))

			float SphereSDF(float3 samplePoint, float3 origin, float radius)
			{
				return length(samplePoint - origin) - radius;
			}

			float BoxSDF(float3 samplePoint, float3 origin, float3 dimensions)
			{
				float3 q = abs(samplePoint - origin) - dimensions;
				return length(max(q, 0.0f)) + min(max(q.x, max(q.y, q.z)), 0.0f);
			}

			float CrossSDF(float3 samplePoint, float3 origin, float size)
			{
				float da = BoxSDF(samplePoint, origin, float3(MAX_DIST, size, size));
				float db = BoxSDF(samplePoint, origin, float3(size, MAX_DIST, size));
				float dc = BoxSDF(samplePoint, origin, float3(size, size, MAX_DIST));

				return min(da, min(db, dc));
			}

			
			float MengerSpongeSDF(float3 p)
			{	
				float s = 1.0;
				float d = BoxSDF(p, float3(-0.0f, 0.0f, 0.0f), float3(1.0f, 1.0f, 1.0f));
				for (int m = 0; m < 5; m++)
				{
					float3 a = mod(p*s, 2.0) - 1;
					s *= 3.0;
					float3 r = 1.0 - 3.0*abs(a);

					float c = CrossSDF(r, float3(0.0f, 0.0f, 0.0f), 1.0f) / s;
					d = max(d, c);
				}

				return d;
			}



			float SceneSDF(float3 samplePoint, float3 origin)
			{
				// The reason for the multiplication and subsequent division by 2.0f is that the formulation 
				// of the Menger SDF I am using expects points to range from -1 to 1, but ours range from 0.5 to 0.5
				// because of how the cube mesh and object space works in Unity
				return MengerSpongeSDF(2.0f * samplePoint) / 2.0f;
			}

			// Estimates the normal by calculating the gradient with three samples
			float3 EstimateNormal(float3 samplePoint, float3 imposterCenter)
			{
				return normalize(float3(SceneSDF(float3(samplePoint.x + EPSILON, samplePoint.y, samplePoint.z), imposterCenter) - SceneSDF(float3(samplePoint.x - EPSILON, samplePoint.y, samplePoint.z), imposterCenter),
										SceneSDF(float3(samplePoint.x, samplePoint.y + EPSILON, samplePoint.z), imposterCenter) - SceneSDF(float3(samplePoint.x, samplePoint.y - EPSILON, samplePoint.z), imposterCenter),
										SceneSDF(float3(samplePoint.x, samplePoint.y, samplePoint.z + EPSILON), imposterCenter) - SceneSDF(float3(samplePoint.x, samplePoint.y, samplePoint.z - EPSILON), imposterCenter)));
			}

			// Uses sphere tracing to march towards the surface
			float MarchToSurface(float3 eye, float3 marchingDirection, float3 imposterCenter, float start, float end)
			{

				float marchRayScale = start;
				for (int i = 0; i < MAX_MARCHING_STEPS; ++i)
				{
					float distanceToSurface = SceneSDF(eye + marchRayScale * marchingDirection, imposterCenter);

					if (distanceToSurface < EPSILON)
					{
						return marchRayScale;
					}

					marchRayScale += distanceToSurface;
					if (marchRayScale >= end)
					{
						return end;
					}
				}

				return end;
			}

			struct appdata
			{
				float4 vertex : POSITION;
			};

			struct v2f
			{
				float4 pos : SV_POSITION;
				float3 rayDir : TEXCOORD0;
				float3 rayOrigin : TEXCOORD1;
			};

			v2f vert(appdata v)
			{
				v2f o;

				// We need to know if this shader is being used with orthographic or perspective projection 
				// because directional shadow casting will use the orthographic, everything else uses perspective
				bool isOrtho = (UNITY_MATRIX_P._m33 == 1.0f);
				float3 worldSpaceRayOrigin = UNITY_MATRIX_I_V._m03_m13_m23;

	
				// The vertex shader needs to give us the ray we'll be marching for our geoemtry
				// the ray aims towards the fragment on the cube mesh that outlines the raymarched geometry
				float3 worldPos = mul(unity_ObjectToWorld, float4(v.vertex.xyz, 1.0));
				float3 worldSpaceRayDir = worldPos - worldSpaceRayOrigin;


				if (isOrtho)
				{
					float3 worldSpaceViewForward = -UNITY_MATRIX_I_V._m02_m12_m22;
					worldSpaceRayDir = worldSpaceViewForward * -dot(worldSpaceRayOrigin, worldSpaceViewForward);
					worldSpaceRayOrigin = worldPos - worldSpaceRayDir;
				}

				o.rayDir = mul(unity_WorldToObject, float4(worldSpaceRayDir, 0.0));
				o.rayOrigin = mul(unity_WorldToObject, float4(worldSpaceRayOrigin, 1.0));
				o.pos = UnityWorldToClipPos(worldPos);

				return o;
			}

			half4 _DiffuseColor;
			half4 _SpecularColor; 
			half4 _Emission;
			half  _Smoothness;


			void frag(v2f i,							// Since we're using deferred, need to write to the g-buffers and depth buffer
				out float outDepth : SV_Depth,					// Depth buffer
				out half4 outDiffuse : SV_Target0,				// RGB is Diffuse Color,  A is Occlusion
				out half4 outSpecSmoothness : SV_Target1,		// RGB is Specular Color, A is Smoothness
				out float4 outNormal : SV_Target2,				// RGB is Normals,        A is typically unused
				out half4 outEmission : SV_Target3				// RGB is Emission,	      A is typically unused
			)
			{

				float3 rayOrigin = i.rayOrigin;

				float3 rayDir = normalize(i.rayDir);

				float3 localOrigin = float3(0.0f, 0.0f, 0.0f);

				float dist = MarchToSurface(rayOrigin, rayDir, localOrigin, MIN_DIST, MAX_DIST);

				
				// This conditional discard might be silly - need to do some testing to see if this helps or not
				if (dist > MAX_DIST - EPSILON)
				{
					discard;
				}

				float3 objectSpacePos = rayOrigin + rayDir * dist;
				float3 worldPos = mul(unity_ObjectToWorld, float4(objectSpacePos, 1.0f));

				float4 clipPos = UnityWorldToClipPos(worldPos);
				outDepth = clipPos.z / clipPos.w;

				// Normals are UNORM
				outNormal = float4((EstimateNormal(objectSpacePos, localOrigin) + float3(1.0f, 1.0f, 1.0f)) / 2.0f, 1.0);
				outDiffuse = _DiffuseColor;
				outSpecSmoothness = half4(_SpecularColor.xyz, _Smoothness);
				outEmission = _Emission;
			}

			half4 frag_shadow(v2f i, out float outDepth : SV_Depth) : SV_Target
			{

				float3 rayOrigin = i.rayOrigin;


				float3 rayDir = normalize(i.rayDir);

				// Might add support for offsetting origins, for now it will be fixed
				float3 localOrigin = float3(0.0f, 0.0f, 0.0f);

				float dist = MarchToSurface(rayOrigin, rayDir, localOrigin, MIN_DIST, MAX_DIST);

				if (dist > MAX_DIST - EPSILON)
				{
					discard;
				}

				float3 objectSpacePos = rayOrigin + rayDir * dist;

				float4 clipPos = UnityClipSpaceShadowCasterPos(objectSpacePos, objectSpacePos);
				clipPos = UnityApplyLinearShadowBias(clipPos);
				outDepth = clipPos.z / clipPos.w;

				return 0;
			}

		ENDCG

			Pass
			{
				Name "DEFERRED"
				Tags{ "LightMode" = "Deferred" }
				Cull Off

				CGPROGRAM
				#pragma vertex vert
				#pragma fragment frag
				ENDCG
			}

			Pass
			{
				Name "SHADOWCASTER"
				Tags { "LightMode" = "ShadowCaster" }
				Cull Off

				ZWrite On ZTest LEqual

				CGPROGRAM
				#pragma vertex vert
				#pragma fragment frag_shadow
				#pragma target 5.0
				#pragma multi_compile_shadowcaster
				ENDCG
			}
	}
}

