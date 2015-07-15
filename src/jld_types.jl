# Controls whether tuples and non-pointerfree immutables, which Julia
# stores as references, are stored inline in compound types when
# possible. Currently this is problematic because Julia fields of these
# types may be undefined.
const INLINE_TUPLE = false
const INLINE_POINTER_IMMUTABLE = false

const EMPTY_TUPLE_TYPE = Tuple{}
typealias TypesType SimpleVector
typealias TupleType{T<:Tuple} Type{T}
typealias CommitParam Union(Type{Val{false}}, Type{Val{true}})
typetuple(types) = Tuple{types...}

## Helper functions
@generated function haspadding{T}(::Type{T})
    isempty(T.types) && return false
    fo = fieldoffsets(T)
    offset = 0
    for i = 1:length(T.types)
        offset != fo[i] && return true
        ty = T.types[i]
        haspadding(ty) && return true
        offset += sizeof(ty)
    end
    return offset != sizeof(T)
end

isghost(T::DataType) = isbits(T) && sizeof(T) == 0

immutable OnDiskRepresentation{Offsets,Types} end
@generated function sizeof{Offsets,Types}(::OnDiskRepresentation{Offsets,Types})
    Offsets[end]+sizeof(Types.parameters[end])
end
@generated function OnDiskRepresentation{T}(::Type{T})
    if sizeof(T) == 0 || T <: Union()
        # A singleton type, so no need to store at all
        return nothing
    elseif applicable(h5sizeof, (Type{T},)) || (isbits(T) && !haspadding(T))
        # Has a specialized convert method or is an unpadded type
        return T
    end

    offsets = [];
    types = [];
    offset = 0;
    for ty in T.types
        if sizeof(ty) == 0 || T <: Union()
            # A ghost type or pointer singleton, so no need to store at all
            h5ty = Nothing
            sz = 0
        elseif applicable(h5sizeof, (Type{ty},))
            # Has a specialized convert method
            h5ty = ty
            sz = h5sizeof(ty)
        elseif isbits(ty)
            if !haspadding(ty)
                h5ty = ty
                sz = sizeof(ty)
            else
                odr = OnDiskRepresentation(ty)
                h5ty = odr
                sz = sizeof(odr)
            end
        else
            h5ty = ReferenceDatatype()
            sz = sizeof(Offset)
        end
        push!(types, h5ty)
        push!(offsets, offset)
        offset += sz
    end

    OnDiskRepresentation{tuple(offsets...),Tuple{types...}}()
end

# Make a compound datatype from a set of names and types
function make_compound(parent::JLDFile, names::AbstractVector, types::SimpleVector)
    h5names = Array(ByteString, length(types))
    offsets = Array(Int, length(types))
    members = Array(H5Datatype, length(types))
    offset = 0
    for i = 1:length(types)
        dtype = h5fieldtype(parent, types[i])
        if isa(dtype, CommittedDatatype)
            # HDF5 cannot store relationships among committed
            # datatypes. We mangle the names by appending a sequential
            # identifier so that we can recover these relationships
            # later.
            h5names[i] = string(names[i], "_", dtype.index)
            dtype = dtype.datatype
        else
            h5names[i] = string(names[i], '_')
        end
        members[i] = dtype::H5Datatype
        offsets[i] = offset
        offset += dtype.size
    end
    CompoundDatatype(offset, h5names, offsets, members)
end

# Write an HDF5 datatype to the file
function commit(parent::JLDFile, dtype::H5Datatype, T::ANY)
    id = length(parent.datatypes)+1
    cdt = CommittedDatatype(commit(parent, dtype), id, dtype)
    push!(parent.datatypes, cdt)
    cdt
end

## Serialization of datatypes to JLD
##
## h5fieldtype - gets the H5Datatype corresponding to a given
## Julia type, when the Julia type is stored as an element of an HDF5
## compound type or array. This is the only function that can operate
## on non-leaf types.
##
## h5type - gets the H5Datatype corresponding to an object of the
## given Julia type. For pointerfree types, this is usually the same as
## the h5fieldtype.
##
## h5convert! - converts data from Julia to HDF5 in a buffer. Most
## methods are dynamically generated by gen_h5convert, but methods for
## special built-in types are predefined.
##
## jlconvert - converts data from HDF5 to a Julia object.
##
## jlconvert! - converts data from HDF5 to Julia in a buffer. This is
## only applicable in cases where fields of that type may not be stored
## as references (e.g., not plain types).

## Special types
##
## To create a special serialization of a datatype, one should:
##
## - Define a method of h5fieldtype that dispatches to h5type
## - Define a method of h5type that constructs the type
## - Define h5convert! and jlconvert
## - If the type is an immutable, define jlconvert!

## HDF5 bits kinds

# This construction prevents these methods from getting called on type unions
typealias PrimitiveTypeTypes Union(Type{Int8}, Type{Int16}, Type{Int32}, Type{Int64}, Type{Int128},
                                   Type{UInt8}, Type{UInt16}, Type{UInt32}, Type{UInt64}, Type{UInt128},
                                   Type{Float16}, Type{Float32}, Type{Float64})
typealias PrimitiveTypes     Union(Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32,
                                   UInt64, UInt128, Float16, Float32, Float64)

h5fieldtype(parent::JLDFile, T::PrimitiveTypeTypes) = h5type(parent, T)

h5type(::JLDFile, T::Union(Type{Int8}, Type{Int16}, Type{Int32}, Type{Int64}, Type{Int128})) =
    FixedPointDatatype(sizeof(T), true)
h5type(::JLDFile, T::Union(Type{UInt8}, Type{UInt16}, Type{UInt32}, Type{UInt64}, Type{UInt128})) =
    FixedPointDatatype(sizeof(T), false)

function jltype(f::JLDFile, dt::FixedPointDatatype)
    signed = dt.bitfield1 == 0x08 ? true : dt.bitfield1 == 0x00 ? false : throw(UnsupportedFeatureException())
    ((dt.bitfield2 == 0x00) & (dt.bitfield3 == 0x00) & (dt.bitoffset == 0) & (dt.bitprecision == dt.size*8)) || 
        throw(UnsupportedFeatureException())
    if dt.size == 64
        return signed ? Int64 : UInt64
    elseif dt.size == 32
        return signed ? Int32 : UInt32
    elseif dt.size == 8
        return signed ? Int8 : UInt8
    elseif dt.size == 16
        return signed ? Int16 : UInt16
    elseif dt.size == 128
        return signed ? Int128 : UInt128
    else
        throw(UnsupportedFeatureException())
    end
end

h5type(::JLDFile, ::Type{Float16}) =
    FloatingPointDatatype(DT_FLOATING_POINT, 0x20, 0x0f, 0x00, 2, 0, 16, 10, 5, 0, 10, 0x0000000f)
h5type(::JLDFile, ::Type{Float32}) =
    FloatingPointDatatype(DT_FLOATING_POINT, 0x20, 0x1f, 0x00, 4, 0, 32, 23, 8, 0, 23, 0x0000007f)
h5type(::JLDFile, ::Type{Float64}) =
    FloatingPointDatatype(DT_FLOATING_POINT, 0x20, 0x3f, 0x00, 8, 0, 64, 52, 11, 0, 52, 0x000003ff)

function jltype(f::JLDFile, dt::FloatingPointDatatype)
    if dt == h5type(f, Float64)
        return Float64
    elseif dt == h5type(f, Float32)
        return Float32
    elseif dt == h5type(f, Float16)
        return Float16
    else
        return UnsupportedFeatureException()
    end
end

h5sizeof(T::PrimitiveTypeTypes) = sizeof(T)
h5convert!{T<:PrimitiveTypes}(out::Ptr, ::Type{T}, ::JLDFile, x::T) =
    unsafe_store!(convert(Ptr{typeof(x)}, out), x)

_jlconvert_bits{T}(::Type{T}, ptr::Ptr) = unsafe_load(convert(Ptr{T}, ptr))
_jlconvert_bits!{T}(out::Ptr, ::Type{T}, ptr::Ptr) =
    (unsafe_store!(convert(Ptr{T}, out), unsafe_load(convert(Ptr{T}, ptr))); nothing)

jlconvert(T::PrimitiveTypeTypes, ::JLDFile, ptr::Ptr) = _jlconvert_bits(T, ptr)
jlconvert!(out::Ptr, T::PrimitiveTypeTypes, ::JLDFile, ptr::Ptr) = _jlconvert_bits!(out, T, ptr)

## ByteStrings

h5fieldtype{T<:ByteString}(parent::JLDFile, ::Type{T}) = h5type(parent, T)

# Stored as variable-length strings
h5type(::JLDFile, ::Type{ASCIIString}) =
    VariableLengthDatatype(DT_VARIABLE_LENGTH, 0x11, 0x00, 0x00, sizeof(Offset)+sizeof(Length),
                           FixedPointDatatype(1, false))
h5type(::JLDFile, ::Type{UTF8String}) =
    VariableLengthDatatype(DT_VARIABLE_LENGTH, 0x11, 0x01, 0x00, sizeof(Offset)+sizeof(Length),
                           FixedPointDatatype(1, false))
h5type(::JLDFile, ::Type{ByteString}) = h5type(UTF8String)

function jltype(f::JLDFile, dt::VariableLengthDatatype)
    if dt == h5type(f, ASCIIString)
        return ASCIIString
    elseif dt == h5type(f, UTF8String)
        return UTF8String
    else
        return UnsupportedFeatureException()
    end
end

# Write variable-length data and store the offset and length to out pointer
function writevlen(out::Ptr, f::JLDFile, x)
    io = f.io
    pos = f.end_of_data
    seek(io, pos)
    write(io, x)
    f.end_of_data += sizeof(x)

    # XXX make sure this is right since docs are missing
    unsafe_store!(convert(Ptr{Offset}, out), pos)
    unsafe_store!(convert(Ptr{Length}, out+sizeof(pos)), sizeof(x))
    nothing
end

# Read variable-length data given offset and length in ptr
function readvlen{T}(::Type{T}, f::JLDFile, ptr::Ptr)
    offset = unsafe_load(convert(Ptr{Offset}, ptr))
    length = unsafe_load(convert(Ptr{Length}, ptr+sizeof(Offset)))
    io = f.io
    seek(io, offset)
    read(io, T, length)
end

h5sizeof{T<:ByteString}(::Type{T}) = sizeof(Offset)+sizeof(Length)
h5convert!{T<:ByteString}(out::Ptr, ::Type{T}, file::JLDFile, x::ByteString) = writevlen(out, file, x)
jlconvert(T::Union(Type{ASCIIString}, Type{UTF8String}), file::JLDFile, ptr::Ptr) = T(readvlen(UInt8, file, ptr))
jlconvert(T::Type{ByteString}, file::JLDFile, ptr::Ptr) = bytestring(readvlen(UInt8, file, ptr))

## UTF16Strings

h5fieldtype(parent::JLDFile, ::Type{UTF16String}) =
    h5type(parent, UTF16String)

# Stored as variable-length
function h5type(parent::JLDFile, ::Type{UTF16String})
    haskey(parent.jlh5type, UTF16String) && return parent.jlh5type[UTF16String]
    commit(parent, VariableLengthDatatype(H5Datatype(UInt16)), UTF16String)
end

h5sizeof(::Type{UTF16String}) = sizeof(Offset)+sizeof(Length)
h5convert!(out::Ptr, ::Type{UTF16String}, file::JLDFile, x::UTF16String) = writevlen(out, file, x.data)
jlconvert(::Type{UTF16String}, file::JLDFile, ptr::Ptr) = UTF16String(readvlen(UTF16String, file, ptr))
h5fieldtype(::Type{UTF16String}) = sizeof(Offset)+sizeof(Length)

## Symbols

h5fieldtype(parent::JLDFile, ::Type{Symbol}) =
    h5type(parent, Symbol)

# Stored as variable-length
function h5type(parent::JLDFile, ::Type{Symbol})
    haskey(parent.jlh5type, Symbol) && return parent.jlh5type[Symbol]
    dtype = h5type(parent, UTF8String)
    commit(parent, dtype, Symbol)
end

h5sizeof(::Type{UTF16String}) = sizeof(Offset)+sizeof(Length)
h5convert!(out::Ptr, ::Type{Symbol}, file::JLDFile, x::Symbol) =
    writevlen(out, file, string(x))
jlconvert(::Type{Symbol}, file::JLDFile, ptr::Ptr) = symbol(readvlen(UInt8, file, ptr))


## BigInts and BigFloats

h5fieldtype(parent::JLDFile, T::Union(Type{BigInt}, Type{BigFloat})) =
    h5type(parent, T)

# Stored as a variable-length string
function h5type(parent::JLDFile, T::Union(Type{BigInt}, Type{BigFloat}))
    haskey(parent.jlh5type, T) && return parent.jlh5type[T]
    commit(parent, h5type(parent, ASCIIString), T)
end

h5sizeof(::Union(Type{BigInt}, Type{BigFloat})) = sizeof(Offset)+sizeof(Length)
h5convert!(out::Ptr, ::Type{BigInt}, file::JLDFile, x::BigInt) =
    writevlen(out, file, base(62, x))
h5convert!(out::Ptr, ::Type{BigFloat}, file::JLDFile, x::BigFloat) =
    writevlen(out, file, string(x))

jlconvert(::Type{BigInt}, file::JLDFile, ptr::Ptr) =
    parse(BigInt, ASCIIString(readvlen(UInt8, file, ptr)), 62)
jlconvert(::Type{BigFloat}, file::JLDFile, ptr::Ptr) =
    parse(BigFloat, ASCIIString(readvlen(UInt8, file, ptr)))

## Types

h5fieldtype{T<:Type}(parent::JLDFile, ::Type{T}) =
    h5type(parent, Type)

# Stored as a variable-length string
function h5type{T<:Type}(parent::JLDFile, ::Type{T})
    haskey(parent.jlh5type, Type) && return parent.jlh5type[Type]
    commit(parent, h5type(parent, UTF8String), Type)
end

h5sizeof{T<:Type}(::Type{T}) = sizeof(Offset)+sizeof(Length)
h5convert!{T<:Type}(out::Ptr, ::Type{T}, file::JLDFile, x::Type) =
    writevlen(ptr, file, full_typename(file, x))
jlconvert{T<:Type}(::Type{T}, file::JLDFile, ptr::Ptr) =
    julia_type(UTF8String(readvlen(UInt8, f, ptr)))

## Pointers

h5type{T<:Ptr}(parent::JLDFile, ::Type{T}) = throw(PointerException())

## Arrays

# These show up as having T.size == 0, hence the need for
# specialization.
h5fieldtype{T,N}(parent::JLDFile, ::Type{Array{T,N}}) = ReferenceDatatype()
h5sizeof{T,N}(::Type{Array{T,N}}) = sizeof(Offset)

## User-defined types
##
## Similar to special types, but h5convert!/jl_convert are dynamically
## generated.

## Tuples

h5fieldtype(parent::JLDFile, T::TupleType) =
    isbits(T) ? h5type(parent, T) : ReferenceDatatype()

function h5type(parent::JLDFile, T::TupleType)
    haskey(parent.jlh5type, T) && return parent.jlh5type[T]
    isleaftype(T) || error("unexpected non-leaf type $T")
    commit(parent, make_compound(parent, 1:length(T.types), T.types), T)
end

@generated function jlconvert(T::TupleType, file::JLDFile, ptr::Ptr)
    ex = Expr(:block)
    args = ex.args
    tup = Expr(:tuple)
    tupargs = tup.args
    types = T.types
    for i = 1:length(types)
        h5offset = dtype.offsets[i]
        field = symbol(string("field", i))

        if dtype.members[i] == ReferenceDatatype()
            push!(args, :($field = read_ref(file, unsafe_load(convert(Ptr{Reference}, ptr)+$h5offset))))
        else
            push!(args, :($field = jlconvert($(types[i]), file, ptr+$h5offset)))
        end
        push!(tupargs, field)
    end

    :($ex; $tup)
end

## All other objects

# For cases not defined above: If the type is mutable and non-empty,
# this is a reference. If the type is immutable, this is a type itself.
if INLINE_POINTER_IMMUTABLE
    h5fieldtype(parent::JLDFile, T::ANY) =
        isleaftype(T) && (!T.mutable || T.size == 0) ? h5type(parent, T) : ReferenceDatatype()
else
    h5fieldtype(parent::JLDFile, T::ANY) =
        isleaftype(T) && (!T.mutable || T.size == 0) && T.pointerfree ? h5type(parent, T) : ReferenceDatatype()
end

function h5type(parent::JLDFile, T::ANY)
    !isa(T, DataType) && unknown_type_err(T)
    T = T::DataType

    haskey(parent.jlh5type, T) && return parent.jlh5type[T]
    isleaftype(T) || error("unexpected non-leaf type ", T)

    if isopaque(T)
        # Empty type or non-basic bitstype
        dtype = OpaqueDatatype(opaquesize(T))
    else
        # Compound type
        dtype = make_compound(parent, fieldnames(T), T.types)
    end
    commit(parent, dtype, T)
end

@generated function jlconvert{T}(::Type{T}, file::JLDFile, ptr::Ptr)
    if isempty(fieldnames(T))
        # Bitstypes
        if T.size == 0
            :($T())
        else
            :(_jlconvert_bits($T, ptr))
        end
    elseif T.size == 0
        # Empty types/immutables
        :(ccall(:jl_new_struct_uninit, Any, (Any,), $T)::$T)
    else
        dtype = make_compound(parent, 1:length(T.types), T)
        ex = Expr(:block)
        args = ex.args
        if T.mutable
            # Types
            fn = fieldnames(T)
            for i = 1:length(dtype.offsets)
                h5offset = dtype.offsets[i]

                if dtype.members[i] == ReferenceDatatype()
                    push!(args, quote
                        ref = unsafe_load(convert(Ptr{Reference}, ptr)+$h5offset)
                        if ref != Reference(0)
                            out.$(fn[i]) = convert($(T.types[i]), read_ref(file, ref))
                        end
                    end)
                else
                    push!(args, :(out.$(fn[i]) = jlconvert($(T.types[i]), file, ptr+$h5offset)))
                end
            end
            quote
                out = ccall(:jl_new_struct_uninit, Any, (Any,), $T)::$T
                $ex
                out
            end
        else
            # Immutables
            if T.pointerfree
                quote
                    out = Array($T, 1)
                    jlconvert!(pointer(out), $T, file, ptr)
                    out[1]
                end
            else
                for i = 1:length(dtype.offsets)
                    h5offset = typeinfo.offsets[i]
                    obj = gensym("obj")
                    if dtype.members[i] == ReferenceDatatype()
                        push!(args, quote
                            ref = unsafe_load(convert(Ptr{Reference}, ptr)+$h5offset)
                            if ref != Reference(0)
                                ccall(:jl_set_nth_field, Void, (Any, Csize_t, Any), out, $(i-1), convert($(T.types[i]), read_ref(file, ref)))
                            end
                        end)
                    else
                        push!(args, :(ccall(:jl_set_nth_field, Void, (Any, Csize_t, Any), out, $(i-1), jlconvert($(T.types[i]), file, ptr+$h5offset))))
                    end
                end
                @eval function jlconvert(::Type{$T}, file::JLDFile, ptr::Ptr)
                    out = ccall(:jl_new_struct_uninit, Any, (Any,), $T)::$T
                    $ex
                    out
                end
            end
        end
    end
end

@generated function jlconvert!{T}(::Type{T}, file::JLDFile, ptr::Ptr)
    if isempty(fieldnames(T))
        if T.size == 0
            !T.mutable ? nothing :
                :(unsafe_store!(convert(Ptr{Ptr{Void}}, out), pointer_from_objref($T())))
        else
            :(_jlconvert_bits!(out, $T, ptr))
        end
    elseif T.size == 0
        nothing
    elseif !isbits(T)
        error("attempted to call jlconvert! on non-isbits type $T")
    else
        dtype = make_compound(parent, 1:length(T.types), T)
        ex = Expr(:block)
        args = ex.args
        jloffsets = fieldoffsets(T)
        for i = 1:length(dtype.offsets)
            h5offset = dtype.offsets[i]
            jloffset = jloffsets[i]
            push!(args, :(jlconvert!(out+$jloffset, $(T.types[i]), file, ptr+$h5offset)))
        end
        push!(args, nothing)
        ex
    end
end

## Common functions for all non-special types (including h5convert!)

# Whether this datatype should be stored as opaque
isopaque(t::TupleType) = t == EMPTY_TUPLE_TYPE
# isopaque(t::DataType) = isempty(fieldnames(t))
isopaque(t::DataType) = isa(t, TupleType) ? t == EMPTY_TUPLE_TYPE : isempty(fieldnames(t))

# The size of this datatype in the HDF5 file (if opaque)
opaquesize(t::TupleType) = 1
opaquesize(t::DataType) = max(1, t.size)

# Whether a type that is stored inline in HDF5 should be stored as a
# reference in Julia. This will only be called such that it returns
# true for some unions of special types defined above, unless either
# INLINE_TUPLE or INLINE_POINTER_IMMUTABLE is true.
uses_reference(T::DataType) = !T.pointerfree
uses_reference(::TupleType) = true
uses_reference(::UnionType) = true

unknown_type_err(T) =
    error("""$T is not of a type supported by JLD
             Please report this error at https://github.com/timholy/HDF5.jl""")

@generated function h5convert!(out::Ptr, odr::OnDiskRepresentation, file::JLDFile, x)
    T = x
    offsets, members = odr.parameters

    getindex_fn = isa(T, TupleType) ? (:getindex) : (:getfield)
    ex = Expr(:block)
    args = ex.args
    for i = 1:length(offsets)
        offset = offsets[i]
        member = members.parameters[i]
        if member == ReferenceDatatype()
            if isa(T, TupleType)
                push!(args, :(unsafe_store!(convert(Ptr{Reference}, out)+$offset,
                                            write_ref(file, x[$i], wsession))))
            else
                push!(args, quote
                    if isdefined(x, $i)
                        ref = write_ref(file, getfield(x, $i), wsession)
                    else
                        ref = Reference(0)
                    end
                    unsafe_store!(convert(Ptr{Reference}, out)+$offset, ref)
                end)
            end
        elseif member != nothing
            push!(args, :(h5convert!(out+$offset, $(member), file, $getindex_fn(x, $i))))
        end
    end
    push!(args, nothing)
    ex
end
# All remaining are just unsafe_store! calls
h5convert!(out::Ptr, ::ANY, file::JLDFile, x) = (unsafe_store!(convert(Ptr{typeof(x)}, out), x); nothing)

## Find the corresponding Julia type for a given HDF5 type

# Type mapping function. Given an HDF5Datatype, find (or construct) the
# corresponding Julia type.
function jldatatype(parent::JLDFile, dtype::H5Datatype)
    class_id = HDF5.h5t_get_class(dtype.id)
    if class_id == HDF5.H5T_STRING
        cset = HDF5.h5t_get_cset(dtype.id)
        if cset == HDF5.H5T_CSET_ASCII
            return ASCIIString
        elseif cset == HDF5.H5T_CSET_UTF8
            return UTF8String
        else
            error("character set ", cset, " not recognized")
        end
    elseif class_id == HDF5.H5T_INTEGER || class_id == HDF5.H5T_FLOAT
        # This can be a performance hotspot
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_DOUBLE) > 0 && return Float64
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_INT64) > 0 && return Int64
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_FLOAT) > 0 && return Float32
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_INT32) > 0 && return Int32
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_UINT8) > 0 && return UInt8
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_UINT64) > 0 && return UInt64
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_UINT32) > 0 && return UInt32
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_INT8) > 0 && return Int8
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_INT16) > 0 && return Int16
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_UINT16) > 0 && return UInt16
        error("unrecognized integer or float type")
    elseif class_id == HDF5.H5T_COMPOUND || class_id == HDF5.H5T_OPAQUE
        addr = HDF5.objinfo(dtype).addr
        haskey(parent.h5jltype, addr) && return parent.h5jltype[addr]

        typename = a_read(dtype, name_type_attr)
        T = julia_type(typename)
        if T == UnsupportedType
            warn("type $typename not present in workspace; reconstructing")
            T = reconstruct_type(parent, dtype, typename)
        end

        if !(T in BUILTIN_TYPES)
            # Call jldatatype on dependent types to validate them and
            # define jlconvert
            if class_id == HDF5.H5T_COMPOUND
                for i = 0:HDF5.h5t_get_nmembers(dtype.id)-1
                    member_name = HDF5.h5t_get_member_name(dtype.id, i)
                    idx = rsearchindex(member_name, "_")
                    if idx != sizeof(member_name)
                        member_dtype = HDF5.t_open(parent.plain, string(pathtypes, '/', lpad(member_name[idx+1:end], 8, '0')))
                        jldatatype(parent, member_dtype)
                    end
                end
            end

            gen_jlconvert(JldTypeInfo(parent, T, false), T)
        end

        # Verify that types match
        newtype = h5type(parent, T, false).dtype
        dtype == newtype || throw(TypeMismatchException(typename))

        # Store type in type index
        index = typeindex(parent, addr)
        parent.jlh5type[T] = H5Datatype(dtype, index)
        parent.h5jltype[addr] = T
        T
    else
        error("unrecognized HDF5 datatype class ", class_id)
    end
end

# Create a Julia type based on the HDF5Datatype from the file. Used
# when the type is no longer available.
function reconstruct_type(parent::JLDFile, dtype::H5Datatype, savedname::AbstractString)
    name = gensym(savedname)
    class_id = HDF5.h5t_get_class(dtype.id)
    if class_id == HDF5.H5T_OPAQUE
        if exists(dtype, "empty")
            @eval (immutable $name; end; $name)
        else
            sz = Int(HDF5.h5t_get_size(dtype.id))*8
            @eval (bitstype $sz $name; $name)
        end
    else
        # Figure out field names and types
        nfields = HDF5.h5t_get_nmembers(dtype.id)
        fieldnames = Array(Symbol, nfields)
        fieldtypes = Array(Type, nfields)
        for i = 1:nfields
            membername = HDF5.h5t_get_member_name(dtype.id, i-1)
            idx = rsearchindex(membername, "_")
            fieldname = fieldnames[i] = symbol(membername[1:idx-1])

            if idx != sizeof(membername)
                # There is something past the underscore in the HDF5 field
                # name, so the type is stored in file
                memberdtype = HDF5.t_open(parent.plain, string(pathtypes, '/', lpad(membername[idx+1:end], 8, '0')))
                fieldtypes[i] = jldatatype(parent, memberdtype)
            else
                memberclass = HDF5.h5t_get_member_class(dtype.id, i-1)
                if memberclass == HDF5.H5T_REFERENCE
                    # Field is a reference, so use Any
                    fieldtypes[i] = Any
                else
                    # Type is built-in
                    memberdtype = HDF5Datatype(HDF5.h5t_get_member_type(dtype.id, i-1), parent.plain)
                    fieldtypes[i] = jldatatype(parent, memberdtype)
                end
            end
        end

        if startswith(savedname, "(") || startswith(savedname, "Core.Tuple{")
            # We're reconstructing a tuple
            typetuple(fieldtypes)
        else
            # We're reconstructing some other type
            @eval begin
                immutable $name
                    $([:($(fieldnames[i])::$(fieldtypes[i])) for i = 1:nfields]...)
                end
                $name
            end
        end
    end
end
