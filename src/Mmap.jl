# This file is a part of Julia. License is MIT: http://julialang.org/license

module Mmap

const PAGESIZE = Int(@unix ? ccall(:jl_getpagesize, Clong, ()) : ccall(:jl_getallocationgranularity, Clong, ()))

# for mmaps not backed by files
type AnonymousMmap <: IO
    name::AbstractString
    readonly::Bool
    create::Bool
end

AnonymousMmap() = AnonymousMmap("",false,true)
Base.isopen(::AnonymousMmap) = true
Base.isreadable(::AnonymousMmap) = true
Base.iswritable(a::AnonymousMmap) = !a.readonly

const INVALID_HANDLE_VALUE = -1
# const used for zeroed, anonymous memory; same value on Windows & Unix; say what?!
gethandle(io::AnonymousMmap) = INVALID_HANDLE_VALUE

# platform-specific mmap utilities
@unix_only begin

const PROT_READ     = Cint(1)
const PROT_WRITE    = Cint(2)
const MAP_SHARED    = Cint(1)
const MAP_PRIVATE   = Cint(2)
const MAP_ANONYMOUS = @osx? Cint(0x1000) : Cint(0x20)
const F_GETFL       = Cint(3)

gethandle(io::IO) = fd(io)

# Determine a stream's read/write mode, and return prot & flags appropriate for mmap
function settings(s::Int, shared::Bool)
    flags = shared ? MAP_SHARED : MAP_PRIVATE
    if s == INVALID_HANDLE_VALUE
        flags |= MAP_ANONYMOUS
        prot = PROT_READ | PROT_WRITE
    else
        mode = ccall(:fcntl,Cint,(Cint,Cint),s,F_GETFL)
        systemerror("fcntl F_GETFL", mode == -1)
        mode = mode & 3
        prot = mode == 0 ? PROT_READ : mode == 1 ? PROT_WRITE : PROT_READ | PROT_WRITE
        if prot & PROT_READ == 0
            throw(ArgumentError("mmap requires read permissions on the file (choose r+)"))
        end
    end
    return prot, flags, (prot & PROT_WRITE) > 0
end

# Before mapping, grow the file to sufficient size
# Note: a few mappable streams do not support lseek. When Julia
# supports structures in ccall, switch to fstat.
grow!(::AnonymousMmap,o::Integer,l::Integer) = return
function grow!(io::IO, offset::Integer, len::Integer)
    pos = position(io)
    filelen = filesize(io)
    if filelen < offset + len
        write(io, Base.zeros(UInt8,(offset + len) - filelen))
        flush(io)
    end
    seek(io, pos)
    return
end
end # @unix_only

@windows_only begin

const PAGE_READONLY          = UInt32(0x02)
const PAGE_READWRITE         = UInt32(0x04)
const PAGE_WRITECOPY         = UInt32(0x08)
const PAGE_EXECUTE_READ      = UInt32(0x20)
const PAGE_EXECUTE_READWRITE = UInt32(0x40)
const PAGE_EXECUTE_WRITECOPY = UInt32(0x80)
const FILE_MAP_COPY          = UInt32(0x01)
const FILE_MAP_WRITE         = UInt32(0x02)
const FILE_MAP_READ          = UInt32(0x04)
const FILE_MAP_EXECUTE       = UInt32(0x20)

function gethandle(io::IO)
    handle = Base._get_osfhandle(RawFD(fd(io))).handle
    systemerror("could not get handle for file to map: $(Base.FormatMessage())", handle == -1)
    return Int(handle)
end

settings(sh::AnonymousMmap) = utf16(sh.name), sh.readonly, sh.create
settings(io::IO) = Ptr{Cwchar_t}(C_NULL), isreadonly(io), true
end # @windows_only

# core impelementation of mmap
immutable Array{T,N} <: AbstractArray{T,N}
    array::Base.Array{T,N} # array with data from memory-mapped region
    iswritable::Bool

    function Mmap.Array{T,N}(::Type{T}, io::IO, dims::NTuple{N,Integer}=(filesize(io),), offset::Integer=position(io); grow::Bool=true, shared::Bool=true)
        # check inputs
        isopen(io) || throw(ArgumentError("$io must be open to mmap"))

        len = prod(dims) * sizeof(T)
        len > 0 || throw(ArgumentError("requested size must be > 0, got $len"))
        len < typemax(Int) - PAGESIZE || throw(ArgumentError("requested size must be < $(typemax(Int)-PAGESIZE), got $len"))

        offset >= 0 || throw(ArgumentError("requested offset must be ≥ 0, got $offset"))

        # shift `offset` to start of page boundary
        offset_page::FileOffset = div(offset, PAGESIZE) * PAGESIZE
        # add (offset - offset_page) to `len` to get total length of memory-mapped region
        mmaplen = (offset - offset_page) + len

        file_desc = gethandle(io)
        # platform-specific mmapping
         @unix_only begin
            prot, flags, iswrite = Mmap.settings(file_desc, shared)
            iswrite && grow && Mmap.grow!(io, offset, len)
            # mmap the file
            ptr = ccall(:jl_mmap, Ptr{Void}, (Ptr{Void}, Csize_t, Cint, Cint, Cint, FileOffset), C_NULL, mmaplen, prot, flags, file_desc, offset_page)
            systemerror("memory mapping failed", reinterpret(Int,ptr) == -1)
        end # @unix_only

        @windows_only begin
            name, readonly, create = settings(io)
            szfile = convert(Csize_t, len + offset)
            readonly && szfile > filesize(io) && throw(ArgumentError("unable to increase file size to $szfile due to read-only permissions"))
            handle = create ? ccall(:CreateFileMappingW, stdcall, Ptr{Void}, (Cptrdiff_t, Ptr{Void}, Cint, Cint, Cint, Cwstring),
                                    file_desc, C_NULL, readonly ? PAGE_READONLY : PAGE_READWRITE, szfile >> 32, szfile & typemax(UInt32), name) :
                              ccall(:OpenFileMappingW, stdcall, Ptr{Void}, (Cint, Cint, Cwstring),
                                readonly ? FILE_MAP_READ : FILE_MAP_WRITE, true, name)
            handle == C_NULL && error("could not create file mapping: $(Base.FormatMessage())")
            ptr = ccall(:MapViewOfFile, stdcall, Ptr{Void}, (Ptr{Void}, Cint, Cint, Cint, Csize_t),
                            handle, readonly ? FILE_MAP_READ : FILE_MAP_WRITE, offset_page >> 32, offset_page & typemax(UInt32), (offset - offset_page) + len)
            ptr == C_NULL && error("could not create mapping view: $(Base.FormatMessage())")
        end # @windows_only
        # convert mmapped region to Julia Array at `ptr + (offset - offset_page)` since file was mapped at offset_page
        A = pointer_to_array(convert(Ptr{T}, UInt(ptr) + UInt(offset - offset_page)), dims)
        array = new{T,N}(A, iswritable(io))
        @unix_only finalizer(A, x -> systemerror("munmap", ccall(:munmap,Cint,(Ptr{Void},Int),ptr,mmaplen) != 0))
        @windows_only finalizer(A, x -> begin
            status = ccall(:UnmapViewOfFile, stdcall, Cint, (Ptr{Void},), ptr)!=0
            status |= ccall(:CloseHandle, stdcall, Cint, (Ptr{Void},), handle)!=0
            status || error("could not unmap view: $(Base.FormatMessage())")
        end)
        return array
    end
end

Mmap.Array{T,N}(::Type{T}, file::AbstractString, dims::NTuple{N,Integer}=(filesize(file),), offset::Integer=Int64(0); grow::Bool=true, shared::Bool=true) =
    open(io->Mmap.Array(T, io, dims, offset; grow=grow, shared=shared), file, isfile(file) ? "r+" : "w+")

# using default type: UInt8
Mmap.Array{N}(io::IO, dims::NTuple{N,Integer}=(filesize(io),), offset::Integer=position(io); grow::Bool=true, shared::Bool=true) =
    Mmap.Array(UInt8, io, dims, offset; grow=grow, shared=shared)
Mmap.Array{N}(file::AbstractString, dims::NTuple{N,Integer}=(filesize(io),), offset::Integer=Int64(0); grow::Bool=true, shared::Bool=true) =
    open(io->Mmap.Array(UInt8, io, dims, offset; grow=grow, shared=shared), file, isfile(file) ? "r+" : "w+")

# using a length argument instead of dims
Mmap.Array(io::IO, len::Integer=filesize(io), offset::Integer=position(io); grow::Bool=true, shared::Bool=true) =
    Mmap.Array(UInt8, io, (len,), offset; grow=grow, shared=shared)
Mmap.Array(file::AbstractString, len::Integer=filesize(file), offset::Integer=Int64(0); grow::Bool=true, shared::Bool=true) =
    open(io->Mmap.Array(UInt8, io, (len,), offset; grow=grow, shared=shared), file, isfile(file) ? "r+" : "w+")

# constructors for non-file-backed (anonymous) mmaps
Mmap.Array{T,N}(::Type{T}, dims::NTuple{N,Integer}; shared::Bool=true) = Mmap.Array(T, AnonymousMmap(), dims, Int64(0); shared=shared)
Mmap.Array{T}(::Type{T}, d::Integer...; shared::Bool=true) = Mmap.Array(T,convert(Tuple{Vararg{Int}}, d); shared=shared)

Base.iswritable(m::Mmap.Array) = m.iswritable
Base.isreadable(m::Mmap.Array) = true

# Array interface
Base.linearindexing{T<:Mmap.Array}(::Type{T}) = Base.LinearFast()
Base.sizeof(a::Mmap.Array) = Base.elsize(a.array) * length(a)
Base.size(m::Mmap.Array) = size(m.array)
Base.similar(a::Mmap.Array, T, dims::Dims)      = Mmap.Array(T, dims)
Base.similar{T}(a::Mmap.Array{T,1})             = Mmap.Array(T, size(a,1))
Base.similar{T}(a::Mmap.Array{T,2})             = Mmap.Array(T, size(a,1), size(a,2))
Base.similar{T}(a::Mmap.Array{T,1}, dims::Dims) = Mmap.Array(T, dims)
Base.similar{T}(a::Mmap.Array{T,1}, m::Int)     = Mmap.Array(T, m)
Base.similar{T}(a::Mmap.Array{T,1}, S)          = Mmap.Array(S, size(a,1))
Base.similar{T}(a::Mmap.Array{T,2}, dims::Dims) = Mmap.Array(T, dims)
Base.similar{T}(a::Mmap.Array{T,2}, m::Int)     = Mmap.Array(T, m)
Base.similar{T}(a::Mmap.Array{T,2}, S)          = Mmap.Array(S, size(a,1), size(a,2))
zeros{T}(::Type{T}, dims::Dims) = Mmap.Array(T, dims)
zeros{T}(::Type{T}, m::Int)     = Mmap.Array(T, m)

@inline Base.getindex{T}(S::Mmap.Array{T}) = getindex(S.array)::T
@inline Base.getindex{T}(S::Mmap.Array{T}, I::Real) = getindex(S.array, I)::T
@inline Base.getindex{T}(S::Mmap.Array{T}, I::AbstractArray) = getindex(S.array, I)::T
@generated function Base.getindex(S::Mmap.Array, I::Union(Real,AbstractVector)...)
    N = length(I)
    Isplat = Expr[:(I[$d]) for d = 1:N]
    quote
        getindex(S.array, $(Isplat...))
    end
end

const WRITEERROR = ArgumentError("mapped-memory is not writable")
@inline Base.setindex!(S::Mmap.Array, x) = iswritable(S) ? setindex!(S.array, x) : throw(WRITEERROR)
@inline Base.setindex!(S::Mmap.Array, x, I::Real) = iswritable(S) ? setindex!(S.array, x, I) : throw(WRITEERROR)
@inline Base.setindex!(S::Mmap.Array, x, I::AbstractArray) = iswritable(S) ? setindex!(S.array, x, I) : throw(WRITEERROR)
@generated function Base.setindex!(S::Mmap.Array, x, I::Union(Real,AbstractVector)...)
    N = length(I)
    Isplat = Expr[:(I[$d]) for d = 1:N]
    quote
        iswritable(S) ? setindex!(S.array, x, $(Isplat...)) : throw(WRITEERROR)
    end
end

# msync flags for unix
const MS_ASYNC = 1
const MS_INVALIDATE = 2
const MS_SYNC = 4

sync!(m::Mmap.Array, flags::Integer=MS_SYNC) = sync!(pointer(m.array), length(m), flags)
function sync!(ptr::Ptr{Void}, len::Integer, flags::Integer=MS_SYNC)
    @unix_only systemerror("msync", ccall(:msync, Cint, (Ptr{Void}, Csize_t, Cint), ptr, len, flags) != 0)
    @windows_only systemerror("could not FlushViewOfFile: $(Base.FormatMessage())",
                    ccall(:FlushViewOfFile, stdcall, Cint, (Ptr{Void}, Csize_t), ptr, len) == 0)
end

type Stream <: IO
    data::Mmap.Array{UInt8,1}
    pos::Int
end

Stream(file::AbstractString) = Stream(Mmap.Array(UInt8,file),1)

Base.eof(m::Stream) = m.pos > length(m.data)
Base.read(m::Stream,::Type{UInt8}) = (b = m.data[m.pos]; m.pos += 1; return b)
Base.peek(m::Stream,::Type{UInt8}) = m.data[m.pos]
Base.position(m::Stream) = m.pos
Base.seekstart(m::Stream) = m.pos = 1
Base.seek(m::Stream, pos) = m.pos = pos
const NEWLINE = UInt8('\n')
function Base.readline(m::Stream)
    buf = IOBuffer()
    while !eof(m)
        b = read(m,UInt8)
        write(buf,b)
        b == NEWLINE && break
    end
    return takebuf_string(buf)
end
function Base.readline(m::Stream,q::UInt8)
    buf = IOBuffer()
    while !eof(m)
        b = read(m,UInt8)
        write(buf,b)
        if b == q
            b = read(m,UInt8)
            write(buf,b)
            while !eof(m) && b != q
                b = read(m,UInt8)
                write(buf,b)
            end
        else
            b == NEWLINE && break
        end
    end
    return takebuf_string(buf)
end

end # module