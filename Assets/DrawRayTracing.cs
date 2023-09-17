using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using UnityEngine;

[StructLayout(LayoutKind.Explicit)]
struct IntToFloat
{
	[FieldOffset(0)] private float f;
	[FieldOffset(0)] private uint i;
	public static float Convert(uint value)
	{
		return new IntToFloat { i = value }.f;
	}
}

[ExecuteAlways, ImageEffectAllowedInSceneView]
public class DrawRayTracing : MonoBehaviour
{
	[SerializeField] private bool _rayTraceInScene = false;
	[SerializeField] private Material _cameraMaterial;
	[SerializeField] private bool _resetRender;

	int _frame = 0;
	RenderTexture _lastFrame;
	Matrix4x4 _lastLocalToWorld;
	Vector4 _lastViewParams;
	float[] _lastSceneData;

	ComputeBuffer _meshes;
	ComputeBuffer _triangles;


    private void Start()
	{
		_frame = 0;
	}

	private void OnRenderImage(RenderTexture source, RenderTexture destination)
	{
		if (_resetRender || (Camera.current.name == "SceneCamera" && _rayTraceInScene))
		{ 
			_frame = 0;
			_resetRender = false;
		}

		if (_rayTraceInScene || Camera.current.name != "SceneCamera")
		{
			SetCamParams(_cameraMaterial, Camera.current);

			SetSceneParams();

			_cameraMaterial.SetInteger("_FrameNum", ++_frame);

			if (_lastFrame == null) _lastFrame = new RenderTexture(source);

			_cameraMaterial.SetTexture("_LastFrame", _lastFrame);
			Graphics.Blit(null, _lastFrame, _cameraMaterial);
			Graphics.Blit(_lastFrame, destination);
		}
		else
		{
			Graphics.Blit(source, destination);
		}
	}

	void SetCamParams(Material material, Camera camera)
	{
		float planeHeight = camera.nearClipPlane * Mathf.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad) * 2;
		float planeWidth = planeHeight * camera.aspect;
		Vector4 viewParams = new Vector3(planeWidth, planeHeight, camera.nearClipPlane);

		material.SetVector("_ViewParams", viewParams);
		material.SetMatrix("_CamToWorld", camera.transform.localToWorldMatrix);

		if (_lastLocalToWorld != camera.transform.localToWorldMatrix || _lastViewParams != viewParams) _frame = 0;

		_lastLocalToWorld = camera.transform.localToWorldMatrix;
		_lastViewParams = viewParams;
	}

	void SetSceneParams()
	{
        MeshFilter[] meshFilters = FindObjectsOfType<MeshFilter>();
        int triAmount = 0;
        foreach (MeshFilter meshFilter in meshFilters) triAmount += meshFilter.sharedMesh.triangles.Length;

        Vector3[] tridata = new Vector3[triAmount];
		int meshFloatAmount = (sizeof(float) * 11 + sizeof(uint) * 2) / sizeof(float);
		float[] meshdata = new float[meshFloatAmount * meshFilters.Length];
		int currVertex = 0;

		for (int i = 0; i < meshFilters.Length; i++)
        {
			Matrix4x4 localToWorld = meshFilters[i].gameObject.transform.localToWorldMatrix;

			//1 start index
			meshdata[i * meshFloatAmount] = IntToFloat.Convert((uint)(currVertex/3));

			//triangle vertex array
            foreach (int j in meshFilters[i].sharedMesh.triangles)
            {
				tridata[currVertex++] = localToWorld.MultiplyPoint3x4(meshFilters[i].sharedMesh.vertices[j]);
            }
			
			//2 end index
			meshdata[i * meshFloatAmount+1] = IntToFloat.Convert((uint)(currVertex / 3));

			//3-8 min and max bounds
			Bounds bounds = meshFilters[i].GetComponent<MeshRenderer>().bounds;

			meshdata[i * meshFloatAmount + 2] = bounds.min.x;
			meshdata[i * meshFloatAmount + 3] = bounds.min.y;
			meshdata[i * meshFloatAmount + 4] = bounds.min.z;

			meshdata[i * meshFloatAmount + 5] = bounds.max.x;
			meshdata[i * meshFloatAmount + 6] = bounds.max.y;
			meshdata[i * meshFloatAmount + 7] = bounds.max.z;

			// 9-11 color
			Material material = meshFilters[i].GetComponent<MeshRenderer>().sharedMaterial;
			bool emission = material.shader.name != "Standard";
			Color color = emission ? material.GetColor("_Color") : material.color;

			meshdata[i * meshFloatAmount + 8] = color.r;
			meshdata[i * meshFloatAmount + 9] = color.g;
			meshdata[i * meshFloatAmount + 10] = color.b;

			//12-13 smoothness and emission
			meshdata[i * meshFloatAmount + 11] = !emission ? material.GetFloat("_Glossiness") : 0f;
			meshdata[i * meshFloatAmount + 12] = emission ? material.GetFloat("_Emission") : 0f;
		}

		if (_lastSceneData == null || !Enumerable.SequenceEqual(meshdata, _lastSceneData))
		{
			_meshes?.Release();
			_triangles?.Release();

            _meshes = new ComputeBuffer(meshFilters.Length, sizeof(float) * 11 + sizeof(uint) * 2);
            _triangles = new ComputeBuffer(triAmount, sizeof(float) * 9);

            _frame = 0;

            _triangles.SetData(tridata);
            _meshes.SetData(meshdata);

            _cameraMaterial.SetBuffer("_Triangles", _triangles);
            _cameraMaterial.SetBuffer("_Meshes", _meshes);
            _cameraMaterial.SetInt("_ObjCount", meshFilters.Length);
        }

        _lastSceneData = meshdata;
    }

    void SetSpheresSceneParams(ComputeBuffer buffer, int floatAmount, MeshRenderer[] meshRenderers)
	{
		float[] data = new float[floatAmount * meshRenderers.Length];
		for (int i = 0; i < meshRenderers.Length; i++)
		{
			Material material = meshRenderers[i].sharedMaterial;

			bool emission = material.shader.name != "Standard";

			Vector3 position = meshRenderers[i].gameObject.transform.position;
			data[i * floatAmount] = position.x;
			data[i * floatAmount + 1] = position.y;
			data[i * floatAmount + 2] = position.z;

			data[i * floatAmount + 3] = meshRenderers[i].gameObject.transform.lossyScale.x / 2;

			Color color = emission ? material.GetColor("_Color") : material.color;
			data[i * floatAmount + 4] = color.r;
			data[i * floatAmount + 5] = color.g;
			data[i * floatAmount + 6] = color.b;

			data[i * floatAmount + 7] = !emission ? material.GetFloat("_Glossiness") : 0f;
			data[i * floatAmount + 8] = emission ? material.GetFloat("_Emission") : 0f;
		}

		buffer.SetData(data);

		_cameraMaterial.SetBuffer("_Spheres", buffer);
		_cameraMaterial.SetInt("_ObjCount", meshRenderers.Length);

		if (_lastSceneData != null && !Enumerable.SequenceEqual(data, _lastSceneData)) _frame = 0;
		_lastSceneData = data;
	}
}
