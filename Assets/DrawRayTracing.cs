using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using Unity.VisualScripting;
using UnityEditor;
using UnityEditor.Experimental.GraphView;
using UnityEditor.SceneManagement;
using UnityEngine;
using static UnityEditor.PlayerSettings;

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

struct BVHNode
{
    public Vector3 aabbMin, aabbMax;
    public uint firstTriOrChild, triCount;
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
    ComputeBuffer _vertices;
    ComputeBuffer _bvhNodes;
    ComputeBuffer _bvhTriIndices;

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

    private void OnApplicationQuit()
    {
        _meshes?.Release();
        _triangles?.Release();
        _vertices?.Release();
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

        int triAmount = 0, vertAmount = 0;
        foreach (MeshFilter meshFilter in meshFilters)
        {
            triAmount += meshFilter.sharedMesh.triangles.Length;
            vertAmount += meshFilter.sharedMesh.vertexCount;
        }

        int[] tridata = new int[triAmount];
        Vector3[] vertdata = new Vector3[vertAmount];
        int meshFloatAmount = (sizeof(float) * 11 + sizeof(uint) * 2) / sizeof(float);
        float[] meshdata = new float[meshFloatAmount * meshFilters.Length];
        int currVertex = 0, currIndex = 0;

        for (int i = 0; i < meshFilters.Length; i++)
        {
            Matrix4x4 localToWorld = meshFilters[i].gameObject.transform.localToWorldMatrix;

            //1 start index
            meshdata[i * meshFloatAmount] = IntToFloat.Convert((uint)currIndex);

            //triangle indices array
            foreach (int j in meshFilters[i].sharedMesh.triangles)
            {
                tridata[currIndex++] = currVertex + j;
            }

            //2 end index
            meshdata[i * meshFloatAmount + 1] = IntToFloat.Convert((uint)currIndex);

            //vertices array
            foreach (Vector3 vert in meshFilters[i].sharedMesh.vertices)
            {
                vertdata[currVertex++] = localToWorld.MultiplyPoint3x4(vert);
            }

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
            print("Recalculating Scene Data...");

            _meshes?.Release();
            _triangles?.Release();
            _vertices?.Release();
            _bvhNodes?.Release();
            _bvhTriIndices?.Release();

            uint[] bvhTriIndices;
            BVHNode[] bvhNodes;
            CalculateBVHScene(tridata, vertdata, out bvhTriIndices, out bvhNodes);

            _meshes = new ComputeBuffer(meshFilters.Length, sizeof(float) * 11 + sizeof(uint) * 2);
            _triangles = new ComputeBuffer(triAmount, sizeof(int));
            _vertices = new ComputeBuffer(vertAmount, sizeof(float) * 3);
            _bvhNodes = new ComputeBuffer(bvhNodes.Length, sizeof(float) * 6 + sizeof(uint) * 2);
            _bvhTriIndices = new ComputeBuffer(triAmount / 3, sizeof(uint));

            _frame = 0;

            _triangles.SetData(tridata);
            _meshes.SetData(meshdata);
            _vertices.SetData(vertdata);
            _bvhNodes.SetData(bvhNodes);
            _bvhTriIndices.SetData(bvhTriIndices);

            _cameraMaterial.SetBuffer("_Triangles", _triangles);
            _cameraMaterial.SetBuffer("_Meshes", _meshes);
            _cameraMaterial.SetBuffer("_Vertices", _vertices);
            _cameraMaterial.SetBuffer("_BVHNodes", _bvhNodes);
            _cameraMaterial.SetBuffer("_BVHTriIndices", _bvhTriIndices);
            _cameraMaterial.SetInt("_ObjCount", meshFilters.Length);
        }

        _lastSceneData = meshdata;
    }


    void CalculateBVHScene(int[] tridata, Vector3[] vertdata, out uint[] indices, out BVHNode[] nodes)
    {
        indices = new uint[tridata.Length / 3];
        for (int i = 0; i < indices.Length; i++) indices[i] = (uint)i;

        nodes = new BVHNode[(tridata.Length / 3) * 2 - 1];

        const uint rootIndex = 0;
        uint nodesUsed = 1;

        //calc centroids
        Vector3[] centroids = new Vector3[tridata.Length / 3];
        for (uint i = 0; i < tridata.Length; i += 3)
            centroids[i / 3] = (GetTriVertex(i) +
                                GetTriVertex(i + 1) +
                                GetTriVertex(i + 2)) / 3;

        nodes[rootIndex].firstTriOrChild = 0;
        nodes[rootIndex].triCount = (uint)tridata.Length / 3;
        UpdateNodeBounds(rootIndex, ref nodes);

        Subdivide(rootIndex, ref indices, ref nodes);

        //foreach (BVHNode node in nodes)
        //{
        //    if (node.triCount > 0)
        //    {
        //        print(node.triCount);
        //        UnityEngine.Debug.DrawLine(centroids[indices[node.firstTriOrChild + 1]], centroids[indices[node.firstTriOrChild + 1]] + Vector3.up * 0.2f, Color.blue, 10f);

        //        for (uint i = node.firstTriOrChild; i < node.firstTriOrChild + node.triCount; i++)
        //        {
        //            //UnityEngine.Debug.DrawLine(centroids[indices[i]], centroids[indices[i]] + Vector3.up * 0.2f);
        //        }
        //    }
        //}


        Vector3 GetTriVertex(uint index)
        {
            return vertdata[tridata[index]];
        }

        void UpdateNodeBounds(uint index, ref BVHNode[] nodes)
        {
            nodes[index].aabbMin = Vector3.positiveInfinity;
            nodes[index].aabbMax = Vector3.negativeInfinity;

            for (uint i = nodes[index].firstTriOrChild; i < nodes[index].firstTriOrChild + nodes[index].triCount; i++)
            {
                nodes[index].aabbMin = Vector3.Min(nodes[index].aabbMin, GetTriVertex(i * 3));
                nodes[index].aabbMin = Vector3.Min(nodes[index].aabbMin, GetTriVertex(i * 3 + 1));
                nodes[index].aabbMin = Vector3.Min(nodes[index].aabbMin, GetTriVertex(i * 3 + 2));
                nodes[index].aabbMax = Vector3.Max(nodes[index].aabbMax, GetTriVertex(i * 3));
                nodes[index].aabbMax = Vector3.Max(nodes[index].aabbMax, GetTriVertex(i * 3 + 1));
                nodes[index].aabbMax = Vector3.Max(nodes[index].aabbMax, GetTriVertex(i * 3 + 2));
            }
        }

        void Subdivide(uint nIndex, ref uint[] indices, ref BVHNode[] nodes)
        {
            if (nodes[nIndex].triCount <= 2) return;

            // determine split axis and position
            Vector3 extent = nodes[nIndex].aabbMax - nodes[nIndex].aabbMin;

            //int axis = 0;
            //if (extent.y > extent.x) axis = 1;
            //if (extent.z > extent[axis]) axis = 2;
            //float splitPos = nodes[nIndex].aabbMin[axis] + extent[axis] / 2;

            // determine split axis using SAH
            int bestAxis = -1, axis;
            float bestPos = 0, bestCost = float.PositiveInfinity;
            for (axis = 0; axis < 3; axis++)
                for (uint i = 0; i < nodes[nIndex].triCount; i++)
                {
                    float candidatePos = centroids[indices[nodes[nIndex].firstTriOrChild + i]][axis];
                    float cost = EvaluateSAH(nodes[nIndex], axis, candidatePos, ref indices);
                    if (cost < bestCost)
                    {
                        bestPos = candidatePos;
                        bestAxis = axis;
                        bestCost = cost;
                    }
                }
            axis = bestAxis;
            float splitPos = bestPos;

            //float splitPos = nodes[nIndex].aabbMin[axis] + extent[axis] / 2;

            //reorder the indices array to split the triangles
            uint l = nodes[nIndex].firstTriOrChild;
            uint h = l + nodes[nIndex].triCount - 1;

            while (l <= h)
            {
                if (centroids[indices[l]][axis] < splitPos)
                    l++;
                else
                { //swap
                    uint temp = indices[l];
                    indices[l] = indices[h];
                    indices[h--] = temp;
                }
            }

            uint leftCount = l - nodes[nIndex].firstTriOrChild;
            if (leftCount == 0 || leftCount == nodes[nIndex].triCount)
            {
                print(nodes[nIndex].triCount);
                return;
            }

            //create child nodes
            uint leftChildIdx = nodesUsed++;
            uint rightChildIdx = nodesUsed++;
            nodes[leftChildIdx].firstTriOrChild = nodes[nIndex].firstTriOrChild;
            nodes[leftChildIdx].triCount = leftCount;
            nodes[rightChildIdx].firstTriOrChild = l;
            nodes[rightChildIdx].triCount = nodes[nIndex].triCount - leftCount;
            nodes[nIndex].firstTriOrChild = leftChildIdx;
            nodes[nIndex].triCount = 0;

            UpdateNodeBounds(leftChildIdx, ref nodes);
            UpdateNodeBounds(rightChildIdx, ref nodes);

            // recurse
            Subdivide(leftChildIdx, ref indices, ref nodes);
            Subdivide(rightChildIdx, ref indices, ref nodes);
        }

        float EvaluateSAH(BVHNode node, int axis, float pos, ref uint[] indices)
        {
            // determine triangle counts and bounds for this split candidate
            Vector3 leftBoxMin = Vector3.positiveInfinity, leftBoxMax = Vector3.negativeInfinity, rightBoxMin = Vector3.positiveInfinity, rightBoxMax = Vector3.negativeInfinity;
            int leftCount = 0, rightCount = 0;
            for (uint i = 0; i < node.triCount; i++)
            {
                uint triIndex = indices[node.firstTriOrChild + i];
                if (centroids[triIndex][axis] < pos)
                {
                    leftCount++;
                    leftBoxMin = Vector3.Min(leftBoxMin, GetTriVertex(triIndex * 3));
                    leftBoxMin = Vector3.Min(leftBoxMin, GetTriVertex(triIndex * 3 + 1));
                    leftBoxMin = Vector3.Min(leftBoxMin, GetTriVertex(triIndex * 3 + 2));
                    leftBoxMax = Vector3.Max(leftBoxMax, GetTriVertex(triIndex * 3));
                    leftBoxMax = Vector3.Max(leftBoxMax, GetTriVertex(triIndex * 3 + 1));
                    leftBoxMax = Vector3.Max(leftBoxMax, GetTriVertex(triIndex * 3 + 2));
                }
                else
                {
                    rightCount++;
                    rightBoxMin = Vector3.Min(rightBoxMin, GetTriVertex(triIndex * 3));
                    rightBoxMin = Vector3.Min(rightBoxMin, GetTriVertex(triIndex * 3 + 1));
                    rightBoxMin = Vector3.Min(rightBoxMin, GetTriVertex(triIndex * 3 + 2));
                    rightBoxMax = Vector3.Max(rightBoxMax, GetTriVertex(triIndex * 3));
                    rightBoxMax = Vector3.Max(rightBoxMax, GetTriVertex(triIndex * 3 + 1));
                    rightBoxMax = Vector3.Max(rightBoxMax, GetTriVertex(triIndex * 3 + 2));
                }
            }

            Vector3 le = leftBoxMax - leftBoxMin;
            Vector3 re = leftBoxMax - leftBoxMin;

            float cost = leftCount * (le.x * le.y + le.y * le.z + le.z * le.x) + rightCount * (re.x * re.y + re.y * re.z + re.z * re.x);
            return cost > 0 ? cost : float.PositiveInfinity;
        }
    }
}