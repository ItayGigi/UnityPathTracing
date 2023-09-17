Shader "Hidden/RayTracer"
{
	Properties
	{
		_MaxBounceCount ("Max Bounce Count", Integer) = 3
		_Samples ("Samples Per Frame", Integer) = 10
		_MaxSamples ("Maximum Samples", Integer) = 100000
		_BlurSize ("Depth Of Field Blur Size", float) = 0.
	}
	SubShader
	{
		// No culling or depth
		Cull Off ZWrite Off ZTest Always

		Pass
		{
			CGPROGRAM

			#pragma vertex vert
			#pragma fragment frag

			#include "UnityCG.cginc"

			struct appdata
			{
				float4 vertex : POSITION;
				float2 uv : TEXCOORD0;
			};

			struct v2f
			{
				float2 uv : TEXCOORD0;
				float4 vertex : SV_POSITION;
			};

			v2f vert (appdata v)
			{
				v2f o;
				o.vertex = UnityObjectToClipPos(v.vertex);
				o.uv = v.uv;
				return o;
			}

			uniform uint _FrameNum;
			uniform uint _MaxSamples;

			uint ns;
			//#define INIT_RNG ns = uint(frame)*uint(resolution.x*resolution.y)+uint(gl_FragCoord.x+gl_FragCoord.y*resolution.x)
			#define INIT_RNG ns = uint(_FrameNum)*uint(_ScreenParams.x*_ScreenParams.y)+uint(_ScreenParams.x*i.uv[0]+i.uv[1]*_ScreenParams.y*_ScreenParams.x)

			// PCG Random Number Generator
			void pcg()
			{
					uint state = ns*747796405U+2891336453U;
					uint word  = ((state >> ((state >> 28U) + 4U)) ^ state)*277803737U;
					ns = (word >> 22U) ^ word;
			}

			// Random Floating-Point Scalars/Vectors
			float rand(){pcg(); return float(ns)/float(0xffffffffU);}
			float2 rand2(){return float2(rand(), rand());}
			float3 rand3(){return float3(rand(), rand(), rand());}
			float4 rand4(){return float4(rand(), rand(), rand(), rand());}

			float RandomNumberNormalDist(){
				float theta = 2 * 3.1415926 * rand();
				float rho = sqrt(-2 * log(rand()));
				return rho * cos(theta);
			}

			float3 RandomInHemisphere(float3 normal){
				float3 vec = normalize(float3(RandomNumberNormalDist(), RandomNumberNormalDist(), RandomNumberNormalDist()));
				return vec * sign(dot(normal, vec));
			}

			struct Ray{
				float3 origin;
				float3 dir;
			};

			struct Material{
				float3 color;
				float smoothness;
				float emission;
			};

			struct Sphere{
				float3 pos;
				float radius;
				Material mat;
			};

			struct Triangle{
				float3 v0;
				float3 v1;
				float3 v2;
			};

			struct MeshInfo{
				uint startIndex;
				uint endIndex;
				float3 minBounds;
				float3 maxBounds;
				Material mat;
			};

			struct HitInfo{
				bool didHit;
				float3 hitPos;
				float3 hitNormal;
				Material hitMat;
			};

			uniform float3 _ViewParams;
			uniform matrix _CamToWorld;
			uniform StructuredBuffer<Sphere> _Spheres;
			uniform int _ObjCount;
			uniform StructuredBuffer<int> _Triangles;
			uniform StructuredBuffer<MeshInfo> _Meshes;
			uniform StructuredBuffer<float3> _Vertices;
			uniform int _MaxBounceCount;
			uniform int _Samples;
			uniform sampler2D _LastFrame;
			uniform float _BlurSize;
			uint hitTriIndex;

			Triangle GetTri(int i){
				Triangle tri = {_Vertices[_Triangles[i]],
								_Vertices[_Triangles[i+1]],
								_Vertices[_Triangles[i+2]]};
				return tri;
			}

			bool RayBoundsIntersection(Ray ray, float3 _min, float3 _max) 
			{ 
					float tmin = (_min.x - ray.origin.x) / ray.dir.x; 
					float tmax = (_max.x - ray.origin.x) / ray.dir.x; 
			
					if (tmin > tmax) {
						float temp = tmin;
						tmin = tmax;
						tmax = temp;
					}
			
					float tymin = (_min.y - ray.origin.y) / ray.dir.y; 
					float tymax = (_max.y - ray.origin.y) / ray.dir.y; 
			
					if (tymin > tymax) {
						float temp = tymin;
						tymin = tymax;
						tymax = temp;
					}
			
					if ((tmin > tymax) || (tymin > tmax)) 
							return false; 
			
					if (tymin > tmin) 
							tmin = tymin; 
			
					if (tymax < tmax) 
							tmax = tymax; 
			
					float tzmin = (_min.z - ray.origin.z) / ray.dir.z; 
					float tzmax = (_max.z - ray.origin.z) / ray.dir.z; 
			
					if (tzmin > tzmax) {
						float temp = tzmin;
						tzmin = tzmax;
						tzmax = temp;
					}
			
					if ((tmin > tzmax) || (tzmin > tmax)) 
							return false; 
			
					if (tzmin > tmin) 
							tmin = tzmin; 
			
					if (tzmax < tmax) 
							tmax = tzmax; 
			
					return true; 
			} 

			float RaySphereIntersection(Ray ray, Sphere sphere){
				float3 origin = ray.origin - sphere.pos;

				float a = dot(ray.dir, ray.dir);
				float b = 2*dot(origin, ray.dir);
				float c = dot(origin, origin) - sphere.radius*sphere.radius;

				float discriminant = b*b - 4*a*c;

				if (discriminant < 0) return -1;

				return (-b - sqrt(discriminant))/(2*a);
			}

			//from scratchapixel
			float RayTriangleIntersection(Ray ray, Triangle tri) {
				float3 normal = cross(tri.v1-tri.v0, tri.v2-tri.v0); //normal

				if (dot(ray.dir, normal) > 0) return -1;

				float denominator = dot(normal, ray.dir);
				if (abs(denominator) < 0.00001) { //ray almost parallel to plane
					return -1;
				}

				float t = -(dot(ray.origin, normal) - dot(normal, tri.v0)) / denominator; //distance to plane
				
				if (t < 0) return -1; //plane behind ray

				float3 P = ray.origin + t*ray.dir; //the intersection point with the plane

				//inside-outside test- to check if the intersection point on a plane is in the triangle
				float3 C; //the cross product

				//edge 0
				C = cross(tri.v1-tri.v0, P-tri.v0);
				if (dot(C, normal) < 0) return -1;

				//edge 1
				C = cross(tri.v2-tri.v1, P-tri.v1);
				if (dot(C, normal) < 0) return -1;

				//edge 2
				C = cross(tri.v0-tri.v2, P-tri.v2);
				if (dot(C, normal) < 0) return -1;

				return t; //intersection point is in the triangle, return distance to plane
			}

			HitInfo CastRaySphere(Ray ray){
				float closestHitDist = -1.;
				Sphere closestHitSphere;
				for (int i = 0; i < _ObjCount; i++){
					float dist = RaySphereIntersection(ray, _Spheres[i]);

					if (dist > 0 && (dist < closestHitDist || closestHitDist == -1)){
						closestHitDist = dist;
						closestHitSphere = _Spheres[i];
					}
				}

				if (closestHitDist < 0){
					HitInfo noHit;
					noHit.didHit = false;
					noHit.hitPos = float3(0., 0., 0.);
					noHit.hitNormal = float3(0., 0., 0.);
					return noHit;
				}

				HitInfo info;
				info.didHit = true;
				info.hitPos = ray.origin + ray.dir * closestHitDist;
				info.hitNormal = normalize(info.hitPos - closestHitSphere.pos);
				info.hitMat = closestHitSphere.mat;

				return info;
			}

			float RayMeshIntersection(Ray ray, MeshInfo mesh){
				float closestDist = -1.;
				for (uint i = mesh.startIndex; i < mesh.endIndex; i += 3){
					float dist = RayTriangleIntersection(ray, GetTri(i));

					if (dist > 0 && (dist < closestDist || closestDist == -1)){
						closestDist = dist;
						hitTriIndex = i;
					}
				}

				return closestDist;
			}

			HitInfo CastRay(Ray ray){
				float closestHitDist = -1.;
				MeshInfo closestHitMesh;
				Triangle closestHitTri;

				for (int i = 0; i < _ObjCount; i++){
					if (!RayBoundsIntersection(ray, _Meshes[i].minBounds, _Meshes[i].maxBounds)) continue;

					float dist = RayMeshIntersection(ray, _Meshes[i]);

					if (dist > 0 && (dist < closestHitDist || closestHitDist == -1)){
						closestHitDist = dist;
						closestHitMesh = _Meshes[i];
						closestHitTri = GetTri(hitTriIndex);
					}
				}

				if (closestHitDist < 0){
					HitInfo noHit;
					noHit.didHit = false;
					noHit.hitPos = float3(0., 0., 0.);
					noHit.hitNormal = float3(0., 0., 0.);
					return noHit;
				}

				HitInfo info;
				info.didHit = true;
				info.hitPos = ray.origin + ray.dir * closestHitDist;
				info.hitNormal = normalize(cross(closestHitTri.v1-closestHitTri.v0, closestHitTri.v2-closestHitTri.v0));
				info.hitMat = closestHitMesh.mat;

				return info;
			}

			float3 Trace(Ray ray){
				float3 rayColor = 1.;
				float3 incomingLight = 0.;

				for (int i=0; i < _MaxBounceCount; i++){
					HitInfo hitInfo = CastRay(ray);

					if (hitInfo.didHit){
						ray.origin = hitInfo.hitPos;
						
						float3 diffuseDir = normalize(hitInfo.hitNormal + normalize(float3(RandomNumberNormalDist(), RandomNumberNormalDist(), RandomNumberNormalDist())));
						float3 specularDir = reflect(ray.dir, hitInfo.hitNormal);

						ray.dir = lerp(diffuseDir, specularDir, hitInfo.hitMat.smoothness);

						if (hitInfo.hitMat.emission == 0.)
							rayColor *= hitInfo.hitMat.color;
						else
							incomingLight += rayColor * hitInfo.hitMat.emission * hitInfo.hitMat.color;
					}
					else{
						break;
					}
				}

				return incomingLight;
			}

			fixed4 frag (v2f i) : SV_Target
			{
				INIT_RNG; //initiate random seed

				if (_FrameNum * _Samples > _MaxSamples) return tex2D(_LastFrame, i.uv); //if there are enough samples, we consider the render complete

				float3 camRight = _CamToWorld._m00_m10_m20;
				float3 camUp = _CamToWorld._m01_m11_m21;

				float3 color = 0.;
				for (int s=0; s < _Samples; s++){ //for each sample
					float3 viewvec = float3(i.uv - 0.5 + (rand2()-0.5)/min(_ScreenParams.x, _ScreenParams.y), 1) * _ViewParams;
					float3 worldpos = mul(_CamToWorld, float4(viewvec, 1)); //the world position that the ray is pointing to on the near plane
					
					Ray ray;

					//calculate a random offset in a circle for the depth of field blur
					float angle = 2 * 3.1415926 * rand();
					float radius = sqrt(rand()*_BlurSize/100.);
					float3 offset = radius*cos(angle)*camRight + radius*sin(angle)*camUp;

					//set ray
					ray.origin = _WorldSpaceCameraPos + offset;
					ray.dir = normalize(worldpos - ray.origin);

					color += Trace(ray);
				}

				float3 currColor = color/_Samples; //average the color over the samples + gamma correction
				float3 lastColor = tex2D(_LastFrame, i.uv);
				
				return float4(currColor * (1./_FrameNum) + lastColor * (1.-1./_FrameNum), 0.); //average this frame's color and the last frame's color
			}
			ENDCG
		}
	}
}
