Shader "Unlit/Emission"
{
    Properties
    {
        _Color ("Color", Color) = (1., 1., 1.)
        _Emission ("Emmision", float) = 1.
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            // make fog work
            #pragma multi_compile_fog

            #include "UnityCG.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                UNITY_FOG_COORDS(1)
                float4 vertex : SV_POSITION;
            };

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                UNITY_TRANSFER_FOG(o,o.vertex);
                return o;
            }

            fixed4 _Color;
            uniform float _Emission;

            fixed4 frag (v2f i) : SV_Target
            {
                // sample the texture
                fixed4 col = _Color*_Emission;
                return col;
            }
            ENDCG
        }
    }
}
