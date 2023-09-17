Shader "Hidden/Average"
{
    Properties
    {
        _OldTex ("Old Texture", 2D) = "white" {}
        _NewTex("Texture", 2D) = "white" {}
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

            sampler2D _OldTex;
            sampler2D _NewTex;
            uniform uint _Samples;

            fixed4 frag (v2f i) : SV_Target
            {
                fixed4 oldcol = tex2D(_OldTex, i.uv);
                fixed4 newcol = tex2D(_NewTex, i.uv);
                
                return 1./_Samples * newcol + (1.-1./_Samples) * oldcol;
            }
            ENDCG
        }
    }
}
