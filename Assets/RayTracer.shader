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

			struct BVHNode{
				float3 aabbMin, aabbMax;
				uint firstTriOrChild, triCount;
			};

			uniform float3 _ViewParams;
			uniform matrix _CamToWorld;
			uniform StructuredBuffer<Sphere> _Spheres;
			uniform int _ObjCount;
			uniform StructuredBuffer<int> _Triangles;
			uniform StructuredBuffer<MeshInfo> _Meshes;
			uniform StructuredBuffer<float3> _Vertices;
			uniform StructuredBuffer<BVHNode> _BVHNodes;
			uniform StructuredBuffer<uint> _BVHTriIndices;
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

			float RayBoundsIntersectionF(Ray ray, float3 _min, float3 _max){
				float tx1 = (_min.x - ray.origin.x) / ray.dir.x, tx2 = (_max.x - ray.origin.x) / ray.dir.x;
				float tmin = min(tx1, tx2), tmax = max(tx1, tx2);
				float ty1 = (_min.y - ray.origin.y) / ray.dir.y, ty2 = (_max.y - ray.origin.y) / ray.dir.y;
				tmin = max(tmin, min(ty1, ty2)), tmax = min(tmax, max(ty1, ty2));
				float tz1 = (_min.z - ray.origin.z) / ray.dir.z, tz2 = (_max.z - ray.origin.z) / ray.dir.z;
				tmin = max(tmin, min(tz1, tz2)), tmax = min(tmax, max(tz1, tz2));
				if (tmax >= tmin && tmax > 0) return tmin; else return 1e30f;
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

			//from scratchapixel
			float MTRayTriangleIntersection(Ray ray, Triangle tri)
			{
				const float EPSILON = 0.0000001;

				float3 v0v1 = tri.v1 - tri.v0;
				float3 v0v2 = tri.v2 - tri.v0;
				float3 pvec = cross(ray.dir, v0v2);
				float det = dot(v0v1, pvec);

				// if the determinant is negative, the triangle is 'back facing'
				// if the determinant is close to 0, the ray misses the triangle
				if (det < EPSILON) return -1;

				float invDet = 1. / det;

				float3 tvec = ray.origin - tri.v0;
				float u = dot(tvec, pvec) * invDet;
				if (u < 0 || u > 1) return -1;

				float3 qvec = cross(tvec, v0v1);
				float v = dot(ray.dir, qvec) * invDet;
				if (v < 0 || u + v > 1) return -1;
				
				return dot(v0v2, qvec) * invDet;
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
					float dist = MTRayTriangleIntersection(ray, GetTri(i));

					if (dist > 0 && (dist < closestDist || closestDist == -1)){
						closestDist = dist;
						hitTriIndex = i;
					}
				}

				return closestDist;
			}

			float NewRayBVHIntersection(Ray ray, uint rootIndex){
				uint curr = rootIndex, stack[64], stackPtr = 0;
				float minDist = -1.;

				while(true){
					if (_BVHNodes[curr].triCount > 0){ //leaf
						for (int i = 0; i < _BVHNodes[curr].triCount; i++){
							float dist = MTRayTriangleIntersection(ray, GetTri(_BVHTriIndices[i + _BVHNodes[curr].firstTriOrChild]*3));
							if (dist > 0 && (dist < minDist || minDist == -1.)){
								minDist = dist;
								hitTriIndex = _BVHTriIndices[i + _BVHNodes[curr].firstTriOrChild]*3;
							}
						}

						if (stackPtr == 0) break;
						else curr = stack[--stackPtr];
					
						continue;
					}

					uint child1 = _BVHNodes[curr].firstTriOrChild;
					uint child2 = _BVHNodes[curr].firstTriOrChild+1;

					float dist1 = RayBoundsIntersectionF(ray, _BVHNodes[child1].aabbMin, _BVHNodes[child1].aabbMax);
					if (dist1 >= minDist && minDist > 0.) dist1 = 1e30f;

					float dist2 = RayBoundsIntersectionF(ray, _BVHNodes[child2].aabbMin, _BVHNodes[child2].aabbMax);
					if (dist2 >= minDist && minDist > 0.) dist2 = 1e30f;

					if (dist1 > dist2){ //swap
						float tempf = dist1;
						dist1 = dist2;
						dist2 = tempf;

						uint tempi = child1;
						child1 = child2;
						child2 = tempi;
					}

					if (dist1 == 1e30f) 
					{
							if (stackPtr == 0) break;
							else curr = stack[--stackPtr];
					}
					else 
					{
							curr = child1;
							if (dist2 != 1e30f) stack[stackPtr++] = child2;
					}
				}

				return minDist;
			}

			float RayBVHIntersection(Ray ray, uint rootIndex){
				#define FROM_PARENT 0
				#define FROM_CHILD 1
				#define FROM_SIBLING 2

				uint current = _BVHNodes[rootIndex].firstTriOrChild;
				int state = FROM_PARENT;
				float closestDist = -1.;

				while (current != rootIndex){
					switch (state){
						case FROM_CHILD:
							if (current == rootIndex) return closestDist;

							bool isFirstChild = false;
							int parent = -1;
							for (int i=0; i<current; i++){
								if (_BVHNodes[i].firstTriOrChild == current && _BVHNodes[i].triCount == 0){
									isFirstChild = true;
									parent = i;
									break;
								}
								if (_BVHNodes[i].firstTriOrChild == current-1 && _BVHNodes[i].triCount == 0){
									parent = i;
								}
							}
							
							if (isFirstChild){
								current++;
								state = FROM_SIBLING;
							}
							else{
								current = parent;
								state = FROM_CHILD;
							}
							break;
						
						case FROM_SIBLING:
							if (!RayBoundsIntersection(ray, _BVHNodes[current].aabbMin, _BVHNodes[current].aabbMax)){
								for (int i=0; i<current; i++){
									if (_BVHNodes[i].firstTriOrChild == current && _BVHNodes[i].triCount == 0){
										current = i;
										break;
									}
									if (_BVHNodes[i].firstTriOrChild == current-1 && _BVHNodes[i].triCount == 0){
										current = i;
									}
								}
								state = FROM_CHILD;
							}
							else if (_BVHNodes[current].triCount > 0){ //leaf
								for (int i=_BVHNodes[current].firstTriOrChild; i <= _BVHNodes[current].firstTriOrChild+_BVHNodes[current].triCount; i++){
									float dist = MTRayTriangleIntersection(ray, GetTri(_BVHTriIndices[i]*3));
									if (dist > 0 && (dist < closestDist || closestDist == -1)){
										closestDist = dist;
										hitTriIndex = _BVHTriIndices[i]*3;
									}
								}
								for (int i=0; i<current; i++){
									if (_BVHNodes[i].firstTriOrChild == current && _BVHNodes[i].triCount == 0){
										current = i;
										break;
									}
									if (_BVHNodes[i].firstTriOrChild == current-1 && _BVHNodes[i].triCount == 0){
										current = i;
									}
								}
								state = FROM_CHILD;
							}
							else{
								current = _BVHNodes[current].firstTriOrChild;
								state = FROM_PARENT;
							}
							break;
						
						case FROM_PARENT:
							if (!RayBoundsIntersection(ray, _BVHNodes[current].aabbMin, _BVHNodes[current].aabbMax)){
								current++;
								state = FROM_SIBLING;
							}
							else if (_BVHNodes[current].triCount > 0){ //leaf
								for (int i=_BVHNodes[current].firstTriOrChild; i < _BVHNodes[current].firstTriOrChild+_BVHNodes[current].triCount; i++){
									float dist = MTRayTriangleIntersection(ray, GetTri(_BVHTriIndices[i]*3));
									//if (dist > 0) return dist;
									if (dist > 0 && (dist < closestDist || closestDist == -1)){
										closestDist = dist;
										hitTriIndex = _BVHTriIndices[i]*3;
									}
								}
								current++;
								state = FROM_SIBLING;
							}
							else{
								current = _BVHNodes[current].firstTriOrChild;
								state = FROM_PARENT;
							}
							break;
					}
				}
				return closestDist;
			}

			HitInfo CastRay(Ray ray){
				float hitDist = NewRayBVHIntersection(ray, 0);
				
				if (hitDist < 0){
					HitInfo noHit;
					noHit.didHit = false;
					noHit.hitPos = float3(0., 0., 0.);
					noHit.hitNormal = float3(0., 0., 0.);
					return noHit;
				}

				MeshInfo hitMesh;
				for (int i = 0; i < _ObjCount; i++)
					if (hitTriIndex >= _Meshes[i].startIndex && hitTriIndex < _Meshes[i].endIndex){
						hitMesh = _Meshes[i];
						break;
					}

				Triangle hitTri = GetTri(hitTriIndex);

				HitInfo info;
				info.didHit = true;
				info.hitPos = ray.origin + ray.dir * hitDist;
				info.hitNormal = normalize(cross(hitTri.v1-hitTri.v0, hitTri.v2-hitTri.v0));
				info.hitMat = hitMesh.mat;

				return info;
			}

			float3 Trace(Ray ray){
				float3 rayColor = 1.;
				float3 incomingLight = 0.;

				for (int i=0; i < _MaxBounceCount; i++){
					HitInfo hitInfo = CastRay(ray);

					if (!hitInfo.didHit)
						break;
					
					ray.origin = hitInfo.hitPos;
					
					float3 diffuseDir = normalize(hitInfo.hitNormal + normalize(float3(RandomNumberNormalDist(), RandomNumberNormalDist(), RandomNumberNormalDist())));
					float3 specularDir = reflect(ray.dir, hitInfo.hitNormal);

					ray.dir = lerp(diffuseDir, specularDir, hitInfo.hitMat.smoothness);

					if (hitInfo.hitMat.emission == 0.)
						rayColor *= hitInfo.hitMat.color;
					else
						incomingLight += rayColor * hitInfo.hitMat.emission * hitInfo.hitMat.color;
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
					
					//return NewRayBVHIntersection(ray, 0);
					//return float4(NewRayBVHIntersection(ray, 0)*ray.dir + ray.origin, 0.);

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
