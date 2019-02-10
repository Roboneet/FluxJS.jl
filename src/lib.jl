using NNlib: padtuple, conv

const to_NCHW = :([0, 3, 1, 2])
const to_NHWC = :([0, 2, 3, 1])
const IntDims = dims(one(Int))

# Library of mathematical functions we consider primitive.
# TODO: store Julia functions and types, to avoid tensorflow.js-specific functions

matVecMul(args...) = *(args...)

@primitive Trace x::AbstractMatrix * y::AbstractMatrix =
  StagedArray(*, x, y)

jscall(::typeof(*), a, b) = jscall(:(math.matMul), b, a)

@primitive Trace x::AbstractMatrix * y::AbstractVector =
  StagedArray(matVecMul, x, y)

jscall(::typeof(matVecMul), a, b) = jscall(:(math.vectorTimesMatrix), b, a)

@primitive Trace x::AbstractArray + y::AbstractArray =
  StagedArray(+, x, y)

jscall(::typeof(+), a, b) = jscall(:(math.add), b, a)

# cat

concat1D(a, b) = vcat(a, b)
concat(a, b) = vcat(a, b)

@primitive Trace vcat(a::AbstractVector, b::AbstractVector) =
  StagedArray(concat1D, a, b)

@primitive Trace vcat(a::AbstractMatrix, b::AbstractMatrix) =
  StagedArray(concat, a, b)

jscall(::typeof(concat1D), a, b) = jscall(:(math.concat1d), jscall(tuple,a, b))
jscall(::typeof(concat), a, b) = jscall(:(math.concat), jscall(tuple, a, b), -1)

# softmax

@primitive Trace softmax(x::AbstractVecOrMat) =
  StagedArray(softmax, x)

jscall(::typeof(softmax), x) = jscall(:(math.softmax), x)

# conv2d

@primitive Trace function (c::Conv)(x)
  out = conv(val(x), c.weight, pad = c.pad, stride = c.stride, dilation = c.dilation)
  pad = 0
  !all(x-> x == c.pad[1], c.pad) ?
    throw(error("Assymetric padding is unsupported by deeplearn-js")) :
    pad = c.pad[1]

  y = StagedArray(conv, stagedinputs(x)..., c.weight, padtuple(val(x),c.stride), pad, padtuple(val(x),c.dilation), v=out)
  σ, b = c.σ, reshape(c.bias, map(_->1, c.stride)..., :, 1)
  out = overdub(Trace(), (x) -> (σ).(x .+ b), y)
  wrap(out, vcall(vertex(DataFlow.Lambda(1, unwrap(out))), x))
end

Base.permutedims(x::Union{StagedArray,IVertex}, p) = jscall(:(math.transpose), x, p)
Base.reverse(x::StagedArray) = jscall(:(math.transpose), x)

# tf-js uses NHWC while js default is NCHW
function jscall(::typeof(conv), x, w, s, p, d)
  _x = permutedims(x, to_NHWC)
  _w = jscall(:(math.reverse), jscall(:(math.transpose), w, :([2, 3, 1,0]), x), :([0,1]))
  _s = reverse(s)
  _d = reverse(d)
  _out = jscall(:(math.conv2d), _x, _w, _s, p, "NHWC", _d, "floor")
  permutedims(_out, to_NCHW)
end

# maxpool

@primitive Trace function maxpool(x::AbstractArray, k; pad = map(_->0,k), stride = k)
  out = maxpool(val(x), k, pad=pad, stride=stride)

  !all(x-> x == pad[1], pad) ?
    throw(error("Assymetric padding is unsupported by deeplearn-js")) :
    pad = pad[1]

  StagedArray(maxpool, x, k, pad, stride, v=out)
end

function jscall(::typeof(maxpool), x, k, pad, stride)
  _x = permutedims(x, to_NHWC)
  _k = reverse(k)
  _s = reverse(stride)
  _out = jscall(:(math.maxPool), _x, _k, _s, pad, "floor")
  permutedims(_out, to_NCHW)
end

# broadcasted ops
bcastable(+, *, /, ^, tanh, σ, relu, leakyrelu, abs, exp, log, -, copy)
# copy for residual blocks

jscall(::typeof(broadcast), ::typeof(+), a, b) = jscall(:(math.add), a, b)
jscall(::typeof(broadcast), ::typeof(*), a, b) = jscall(:(math.mul), a, b)
jscall(::typeof(broadcast), ::typeof(/), a, b) = jscall(:(math.div), a, b)
jscall(::typeof(broadcast), ::typeof(^), a, b) = jscall(:(math.pow), a, b)
jscall(::typeof(broadcast), ::typeof(tanh), x) = jscall(:(math.tanh), x)
jscall(::typeof(broadcast), ::typeof(σ), x) = jscall(:(math.sigmoid), x)
jscall(::typeof(broadcast), ::typeof(relu), x) = jscall(:(math.relu), x)
jscall(::typeof(broadcast), ::typeof(leakyrelu), x) = jscall(:(math.leakyRelu), x, 0.01)
jscall(::typeof(broadcast), ::typeof(leakyrelu), x, a) = jscall(:(math.leakyRelu), x, a)
jscall(::typeof(broadcast), ::typeof(abs), x) = jscall(:(math.abs), x)
jscall(::typeof(broadcast), ::typeof(exp), x) = jscall(:(math.exp), x)
jscall(::typeof(broadcast), ::typeof(log), x) = jscall(:(math.log), x)
jscall(::typeof(broadcast), ::typeof(-), x, y) = jscall(:(math.sub), x, y)
jscall(::typeof(broadcast), ::typeof(copy), x) = jscall(:(flux.slice), x)

# reshape

@primitive Trace Base.reshape(parent, dims...) =
  ! any(x -> x isa StagedArray, (parent, dims...)) ?
  trace(reshape, parent, dims...) :
  begin
    dims = any(x -> val(x) isa Colon, dims) ? begin
      p = 1
      pos = 0
      for i=1:length(dims)
        !( val(dims[i]) isa Colon ) ?
         p = tracecall((p, v)-> p*v, p, dims[i]) : (pos = i)
      end
      c = tracecall((x, p) -> (count(x)/p), parent, p)
      (dims[1:pos-1]..., c, dims[pos+1:end]...)
    end : dims
    StagedArray(reshape, parent, dims..., v=reshape(val(parent), Int.(val.(dims))...))
  end

Base.count(x::AbstractArray) = prod(size(x))
@primitive Trace Base.count(x::AbstractArray) = StagedArray(getindex, x, :(String("size")), v=count(val(x)))

jscall(::typeof(reshape), p, dims...) =
  jscall(:(math.reshape), p, jscall(tuple, reverse(dims)...))

# size
@primitive Trace Base.size(x::StagedArray) =
  StagedArray(getindex, x, :(String("shape")), v=size(val(x)))

@primitive ctx::Trace Base.size(x, i) =
  ! any(x -> x isa StagedArray, (x, i)) ?
  trace(size, x, i) :
  begin
    if x isa StagedArray
      _size = tracecall((x) -> size(x), x, meta=ctx)
    else
      _size = size(x)
    end
    StagedArray(js_invindex, _size, i, v=size(val(x))[val(i)])
  end
  # begin
  #   index, _size = invertedindex(x, i)
  #   StagedArray(getindex, _size, index, v=size(val(x))[val(i)])
  # end

# # gate ( for LSTM and GRU )
@primitive ctx::Trace function Flux.gate(x::AbstractArray, h, n)
  out = Flux.gate(val(x), val(h), val(n))
  _start =  overdub(Trace(), (h, n) -> h * (n-1), h, n)
  StagedArray(view, x, _start, h, v=out)
end

jscall(::typeof(view), x, start, length) =
  jscall(:(math.slice), x, start, length)

# @primitive Trace Base.getfield(x, i) =
#   ! any(x -> x isa StagedArray, (x, i)) ?
#   trace(getfield, x, i) :
#   StagedArray(getindex, x, "$i", v=getfield(val(x), val(i)))
#
# @primitive Trace Base.getfield(x::StagedArray, i::Union{StagedArray{Int,IntDims},Int}) =
#   StagedArray(getindex, x, primitive(Trace(), -, i, 1), v=getfield(val(x), val(i)))
#
# @primitive Trace Base.getfield(x, i::StagedArray{Int,IntDims}) =
#   StagedArray(getindex, x, primitive(Trace(), -, i, 1), v=getfield(val(x), val(i)))


Base.getindex(x::StagedArray, i...) =
  StagedArray(js_getindex, x, i...)

js_getindex(x, i...) = getindex(x, i...)
jscall(::typeof(js_getindex), x, i...) =
  jscall(:(flux.getindex), x, i...)

js_invindex(x, i...) = getindex(x, i...)
jscall(::typeof(js_invindex), x, i...) =
  jscall(:(flux.invindex), x, i...)


# Base.getindex(x::StagedArray, i) = StagedArray(getindex, x, i - 1, v=getindex(val(x), i))
# # Base.getindex(x::StagedArray, i::Int) = StagedArray(getindex, x, i - 1, v=getindex(val(x), i))
#
# @primitive Trace Base.getindex(t::StagedArray, i::Int) =
#   StagedArray(getindex, t, i - 1, v = val(t)[i])
#
# @primitive Trace function Base.getindex(t, i::StagedArray{Int,IntDims})
#   index = overdub(Trace(), x -> x - 1, i)
#   StagedArray(getindex, t, i, v = val(t)[val(i)])
# end
#
# @primitive Trace tuple(args...) = args
#
add(x, y) = x + y
sub(x, y) = x - y
mul(x, y) = x * y
div(x, y) = x / y

# for StagedArray{Int}
function binary_op(op, sub)
  @eval @primitive Trace ($op)(x::T, y::T) where {T<:StagedArray{<:Number,IntDims}} = StagedArray($sub, x, y)
  @eval @primitive Trace ($op)(x::T, y::S) where {T<:StagedArray{S,IntDims}} where {S<:Number} = StagedArray($sub, x, y)
  @eval @primitive Trace ($op)(x::S, y::T) where {T<:StagedArray{S,IntDims}} where {S<:Number} = StagedArray($sub, x, y)
end

binary_op(+, add)
binary_op(*, mul)
binary_op(-, sub)
binary_op(/, div)

jscall(::typeof(add), x, y) = jscall(:(+), x, y)
jscall(::typeof(sub), x, y) = jscall(:(-), x, y)
jscall(::typeof(mul), x, y) = jscall(:(*), x, y)
jscall(::typeof(div), x, y) = jscall(:(/), x, y)
#
# @primitive Trace function (BN::BatchNorm)(x)
#   μ, σ, γ, β, λ = BN.μ, BN.σ, BN.γ, BN.β, BN.λ
#
#   dims = trace(x -> length(size(x)), stagedinputs(x)...)
#   channels = trace((x,dims) -> size(x, dims - 1), stagedinputs(x)..., dims)
#
#   affine_shape = trace((dims, channels) -> begin
#     affine_shape = onesArr(Int, dims)
#     affine_shape[dims-1] = channels # not traced
#     affine_shape
#   end, dims, channels)
#
#   dims_ = trace((dims)-> dims - 2, dims)
#
#   out = trace((x) -> begin
#     k = Tuple(affine_shape)
#     μ = reshape(μ, affine_shape...)
#     σ = reshape(σ, affine_shape...)
#     γ = reshape(γ, affine_shape...)
#     β = reshape(β, affine_shape...)
#     λ.(γ .* ((x .- μ) ./ σ) .+ β)
#   end, stagedinputs(x)...)
#
#   f = vertex(DataFlow.Lambda(1,
#     vertex(DataFlow.Do(),
#       vcall(setindex!, unwrap(affine_shape), unwrap(channels), unwrap(dims_)),
#       unwrap(out))
#       ))
#
#   wrap(out, vcall(f, x))
# end
#
# @primitive Trace Base.length(s::StagedArray) = StagedArray(getindex, s, :(String("length")), v=length(val(s)))
# @primitive Trace Base.ones(t, i::StagedArray) = StagedArray(ones, t, i)
# @primitive Trace Tuple(t::StagedArray) = StagedArray(Flux.data, t, v=Tuple(val(t)))
# @primitive Trace Flux.data(t::StagedArray) = StagedArray(Flux.data, t)
#
# jscall(::typeof(Base.ones), t, i) = jscall(:(tf.ones), jscall(tuple, i), dtype(t))
# jscall(::typeof(Flux.data), t) = jscall(:(flux.data), t)
#
# dtype(::Type{Int}) = :(String("int32"))
# dtype(::Type{Float32}) = :(String("float32"))
#
# onesArr(t, i) = ones(t, i)
# @primitive Trace onesArr(t, i::StagedArray) = StagedArray(onesArr, t, i)
# jscall(::typeof(onesArr), t, i) = jscall(:([].fill.apply), jscall(:(Array), i), :([1]))
#
# @primitive Trace Base.setindex!(A, X, i) =
#   any(x -> x isa StagedArray , (A, X)) ?
#   StagedArray(setindex!, A, X, trace((i) -> i - 1, i), v = setindex!(val(A), val(X), val(i))) :
#   trace(setindex!, A, X, i)
#
@primitive Trace copy(A::StagedArray{AbstractArray,N}) where N =
  StagedArray(copy,A)

jscall(::typeof(copy), A) = jscall(:(flux.slice), A)

function invertedindex(x::AbstractArray, i)
  _size = trace((x) -> size(x), x)
  index = trace((s, i)-> (length(s) - i), _size ,i)
  return index, _size
end

# @primitive Trace Base.iterate(x::StagedArray{T,N}) where {T,N} = StagedArray(iterate, x)
# @primitive Trace Base.iterate(x::StagedArray{T,N}, state) where {T,N} = StagedArray(iterate, x, state)
# jscall(::typeof(iterate), args...) = jscall(:(flux.iterate), args...)
