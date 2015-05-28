reload("Mmap")
using Base.Test

file = tempname()
s = open(file, "w") do f
    write(f, "Hello World\n")
end
t = "Hello World".data
@test Mmap.Array(UInt8, file, (11,1,1)).array == reshape(t,(11,1,1))
gc()
@test Mmap.Array(UInt8, file, (1,11,1)).array == reshape(t,(1,11,1))
gc()
@test Mmap.Array(UInt8, file, (1,1,11)).array == reshape(t,(1,1,11))
gc()
@test_throws ArgumentError Mmap.Array(UInt8, file, (11,0,1)) # 0-dimension results in len=0
@test Mmap.Array(UInt8, file, (11,)).array == t
gc()
@test Mmap.Array(UInt8, file, (1,11)).array == t'
gc()
@test_throws ArgumentError Mmap.Array(UInt8, file, (0,12))
m = Mmap.Array(UInt8, file, (1,2,1))
@test m == reshape("He".data,(1,2,1))
m=nothing; gc()

s = open(f->f,file,"w")
@test_throws ArgumentError Mmap.Array(file) # requested len=0 on empty file
@test_throws ArgumentError Mmap.Array(file,0)
m = Mmap.Array(file,12)
m[:] = "Hello World\n".data
Mmap.sync!(m)
m=nothing; gc()
@test open(readall,file) == "Hello World\n"

s = open(file, "r")
close(s)
@test_throws Base.UVError Mmap.Array(s) # closed IOStream
@test_throws ArgumentError Mmap.Array(s,12,0) # closed IOStream
@test_throws SystemError Mmap.Array("")

# negative length
@test_throws ArgumentError Mmap.Array(file, -1)
# negative offset
@test_throws ArgumentError Mmap.Array(file, 1, -1)

for i = 0x01:0x0c
    @test length(Mmap.Array(file, i)) == Int(i)
end
gc()

sz = filesize(file)
m = Mmap.Array(file, sz+1)
@test length(m) == sz+1 # test growing
@test m[end] == 0x00
m=nothing; gc()
sz = filesize(file)
m = Mmap.Array(file, 1, sz)
@test length(m) == 1
@test m[1] == 0x00
m=nothing; gc()
sz = filesize(file)
# test where offset is actually > than size of file; file is grown with zeroed bytes
m = Mmap.Array(file, 1, sz+1)
@test length(m) == 1
@test m[1] == 0x00
m=nothing; gc()

s = open(file, "r")
m = Mmap.Array(s)
@test_throws ArgumentError m[5] = UInt8('x') # tries to setindex! on read-only array
m=nothing; gc()

s = open(file, "w") do f
    write(f, "Hello World\n")
end

s = open(file, "r")
m = Mmap.Array(s)
close(s)
m=nothing; gc()
m = Mmap.Array(file)
s = open(file, "r+")
c = Mmap.Array(s)
d = Mmap.Array(s)
c[1] = UInt8('J')
Mmap.sync!(c)
close(s)
@test m[1] == UInt8('J')
@test d[1] == UInt8('J')
m=nothing; c=nothing; d=nothing; gc()

s = open(file, "w") do f
    write(f, "Hello World\n")
end

s = open(file, "r")
@test isreadonly(s) == true
c = Mmap.Array(UInt8, s, (11,))
@test c == "Hello World".data
c=nothing; gc()
c = Mmap.Array(UInt8, s, (UInt16(11),))
@test c == "Hello World".data
c=nothing; gc()
@test_throws ArgumentError Mmap.Array(UInt8, s, (Int16(-11),))
@test_throws ArgumentError Mmap.Array(UInt8, s, (typemax(UInt),))
close(s)
s = open(file, "r+")
@test isreadonly(s) == false
c = Mmap.Array(UInt8, s, (11,))
c[5] = UInt8('x')
Mmap.sync!(c)
close(s)
s = open(file, "r")
str = readline(s)
close(s)
@test startswith(str, "Hellx World")
c=nothing; gc()

c = Mmap.Array(file)
@test c == "Hellx World\n".data
c=nothing; gc()
c = Mmap.Array(file, 3)
@test c == "Hel".data
c=nothing; gc()
s = open(file, "r")
c = Mmap.Array(s, 6)
@test c == "Hellx ".data
close(s)
c=nothing; gc()
c = Mmap.Array(file, 5, 6)
@test c == "World".data
c=nothing; gc()

s = open(file, "w")
write(s, "Hello World\n")
close(s)

# test Mmap.Array
m = Mmap.Array(file)
t = "Hello World\n"
for i = 1:12
    @test m[i] == t.data[i]
end
@test_throws BoundsError m[13]
m=nothing; gc()

m = Mmap.Array(file,6)
@test m[1] == "H".data[1]
@test m[2] == "e".data[1]
@test m[3] == "l".data[1]
@test m[4] == "l".data[1]
@test m[5] == "o".data[1]
@test m[6] == " ".data[1]
@test_throws BoundsError m[7]
m=nothing; gc()

m = Mmap.Array(file,2,6)
@test m[1] == "W".data[1]
@test m[2] == "o".data[1]
@test_throws BoundsError m[3]
m=nothing; gc()

# mmap with an offset
A = rand(1:20, 500, 300)
fname = tempname()
s = open(fname, "w+")
write(s, size(A,1))
write(s, size(A,2))
write(s, A)
close(s)
s = open(fname)
m = read(s, Int)
n = read(s, Int)
A2 = Mmap.Array(Int, s, (m,n))
@test A == A2.array
seek(s, 0)
A3 = Mmap.Array(Int, s, (m,n), convert(FileOffset,2*sizeof(Int)))
@test A == A3.array
A4 = Mmap.Array(Int, s, (m,150), convert(FileOffset,(2+150*m)*sizeof(Int)))
@test A[:, 151:end] == A4.array
close(s)
A2=nothing; A3=nothing; A4=nothing; gc()
rm(fname)

# AnonymousMmap
m = Mmap.AnonymousMmap()
@test m.name == ""
@test !m.readonly
@test m.create
@test isopen(m)
@test isreadable(m)
@test iswritable(m)

m = Mmap.Array(UInt8, 12)
@test length(m) == 12
@test all(m .== 0x00)
@test m[1] === 0x00
@test m[end] === 0x00
m[1] = 0x0a
Mmap.sync!(m)
@test m[1] === 0x0a
m = Mmap.Array(UInt8, 12; shared=false)
m = Mmap.Array(Int, 12)
@test length(m) == 12
@test all(m .== 0)
@test m[1] === 0
@test m[end] === 0
m = Mmap.Array(Float64, 12)
@test length(m) == 12
@test all(m .== 0.0)
m = Mmap.Array(Int8, (12,12))
@test size(m) == (12,12)
@test all(m == zeros(Int8, (12,12)))
@test iswritable(m)
@test isreadable(m)
@test sizeof(m) == prod((12,12))
n = similar(m)
@test typeof(n) <: Mmap.Array{Int8,2}
@test all(n .== Int8(0))
@test size(n) == (12,12)
n = similar(m, (2,2))
@test typeof(n) <: Mmap.Array{Int8,2}
@test all(n .== Int8(0))
@test size(n) == (2,2)
n = similar(m, 12)
@test length(n) == 12
@test size(n) == (12,)
@test all(n .== Int8(0))
@test typeof(n) <: Mmap.Array{Int8,1}
n = similar(m, UInt8)
@test typeof(n) <: Mmap.Array{UInt8,2}
@test size(n) == size(m)
@test eltype(n) == UInt8
@test all(n .== 0x00)
m = Mmap.zeros(UInt8, (12,12))
@test n == m

# Array interface tests
m = Mmap.Array(file)
@test size(m) == (12,)
@test length(m) == 12
@test ndims(m) == 1
@test endof(m) == 12
@test first(m) == 0x48
@test last(m) == 0x0a
@test sizeof(m) == 12
@test eltype(m) == UInt8
@test Base.elsize(m) == 1

@test !isempty(m)

@test all(copy(m) == m)

n = similar(m)
copy!(n,m)
@test n == m

fill!(n, 0x00)
@test all(n .== 0x00)

# iteration
for i in n
    @test i == 0x00
end

@test 0x00 in n

@test reverse(m) == reverse("Hello World\n".data)
@test map(x->x*0x02, m) == map(x->x*0x02,"Hello World\n".data)

n = Mmap.Array(file)
@test m == n
mn = vcat(m,n)
@test length(mn) == length(m) + length(n)
@test mn[1:length(m)] == m
@test mn[length(m)+1:end] == n
@test size(mn) == (24,)
m_n = hcat(m,n)
@test size(m_n) == (12,2)
@test m_n[:,1] == m
@test m_n[:,2] == n

f = float(m)
@test eltype(f) == Float64

n = Mmap.Array(file, (2,6))
n_r = reshape(n, (12,))
@test [i for i in n] == [i for i in n_r]
