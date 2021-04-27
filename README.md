# JLD2DebugTools
Install via
```
] add git@github.com:JonasIsensee/JLD2DebugTools.git
```

Example usage:

```julia
julia> using JLD2DebugTools

julia> jldsave("test.jld2", true; a = rand(10000), b=zeros(20,20), c=42, d="hello world!", e=[(3,(1,(4,)))])
[ Info: Attempting to dynamically load CodecZlib

julia> jldopen("test.jld2") do f
       committed_datatypes(f); println(); for key in keys(f); describe(f, key);println() end
       end
1) DataType
2) Tuple{Int64}
3) Tuple{Int64, Tuple{Int64}}
4) Tuple{Int64, Tuple{Int64, Tuple{Int64}}}

Dataset "a" at position: JLD2.RelOffset(0x0000000000000030)
Storage type: Chunked Storage
Dataspace: Simple
Dimensions: (10000,)
Type signature: Array{Float64, 1}
Compressed with ZlibCompressor
Bytes on disk: 75290

Dataset "b" at position: JLD2.RelOffset(0x00000000000126c1)
Storage type: Compact Storage
Dataspace: Simple
Dimensions: (20, 20)
Type signature: Array{Float64, 2}
Bytes on disk: 3200

Dataset "c" at position: JLD2.RelOffset(0x000000000001338b)
Storage type: Compact Storage
Dataspace: Scalar
Dimensions: ()
Type signature: Int64
Bytes on disk: 8

Dataset "d" at position: JLD2.RelOffset(0x00000000000133c4)
Storage type: Compact Storage
Dataspace: Scalar
Dimensions: ()
Type signature: String
Bytes on disk: 12

Dataset "e" at position: JLD2.RelOffset(0x00000000000146fe)
Storage type: Compact Storage
Dataspace: Simple
Dimensions: (1,)
Type signature: Array{Tuple{Int64, Tuple{Int64, Tuple{Int64}}}, 1}
Bytes on disk: 24
```