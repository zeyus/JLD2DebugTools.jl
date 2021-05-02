
struct LoadedDataset
    name::String
    parent::Group
    header_offset#::RelOffset
    header_size::Int
    data_offset#::RelOffset
    data_length::Int
    dataspace
    datatype_class
    datatype_offset
    filter_id
    attrs
    layout_class # Compact / Contiguous / Chunked
    #storage_message
    juliatype
    odr

end

read_dataset(f::JLDFile, name::AbstractString) =
    read_dataset(f.root_group, name)

function read_dataset(g::Group, name::AbstractString)
    f = g.f
    f.n_times_opened == 0 && throw(ArgumentError("file is closed"))

    (g, name) = pathize(g, name, false)

    roffset = lookup_offset(g, name)
    if roffset == UNDEFINED_ADDRESS
        haskey(g.unwritten_child_groups, name) && return g.unwritten_child_groups[name]
        throw(KeyError(name))
    end

    if isgroup(f, roffset)
        let loaded_groups = f.loaded_groups
            get!(()->load_group(f, roffset), loaded_groups, roffset)
        end
    else
        read_dataset(g, roffset, name)
    end
end

function read_dataset(group::Group, offset::RelOffset, name)
    f = group.f
    io = f.io
    seek(io, fileoffset(f, offset))
    cio = begin_checksum_read(io)
    sz = read_obj_start(cio)
    pmax = position(cio) + sz

    # Messages
    dataspace = ReadDataspace()
    attrs = EMPTY_READ_ATTRIBUTES
    datatype_class::UInt8 = 0
    datatype_offset::Int64 = 0
    data_offset::Int64 = 0
    data_length::Int = -1
    chunked_storage::Bool = false
    filter_id::UInt16 = 0

    storage_type = 0xFF
    while position(cio) <= pmax-4
        msg = jlread(cio, HeaderMessage)
        endpos = position(cio) + msg.size
        if msg.msg_type == HM_DATASPACE
            dataspace = read_dataspace_message(cio)
        elseif msg.msg_type == HM_DATATYPE
            datatype_class, datatype_offset = read_datatype_message(cio, f, (msg.flags & 2) == 2)
        elseif msg.msg_type == HM_FILL_VALUE
            (jlread(cio, UInt8) == 3 && jlread(cio, UInt8) == 0x09) || throw(UnsupportedFeatureException())
        elseif msg.msg_type == HM_DATA_LAYOUT
            jlread(cio, UInt8) == 4 || throw(UnsupportedVersionException())
            storage_type = jlread(cio, UInt8)
            if storage_type == LC_COMPACT_STORAGE
                data_length = jlread(cio, UInt16)
                data_offset = position(cio)
            elseif storage_type == LC_CONTIGUOUS_STORAGE
                data_offset = fileoffset(f, jlread(cio, RelOffset))
                data_length = jlread(cio, Length)
            elseif storage_type == LC_CHUNKED_STORAGE
                # TODO: validate this
                flags = jlread(cio, UInt8)
                dimensionality = jlread(cio, UInt8)
                dimensionality_size = jlread(cio, UInt8)
                skip(cio, Int(dimensionality)*Int(dimensionality_size))

                chunk_indexing_type = jlread(cio, UInt8)
                chunk_indexing_type == 1 || throw(UnsupportedFeatureException("Unknown chunk indexing type"))
                data_length = jlread(cio, Length)
                jlread(cio, UInt32)
                data_offset = fileoffset(f, jlread(cio, RelOffset))
                chunked_storage = true
            else
                throw(UnsupportedFeatureException("Unknown data layout"))
            end
        elseif msg.msg_type == HM_FILTER_PIPELINE
            version = jlread(cio, UInt8)
            version == 2 || throw(UnsupportedVersionException("Filter Pipeline Message version $version is not implemented"))
            nfilters = jlread(cio, UInt8)
            nfilters == 1 || throw(UnsupportedFeatureException())
            filter_id = jlread(cio, UInt16)
            issupported_filter(filter_id) || throw(UnsupportedFeatureException("Unknown Compression Filter $filter_id"))
        elseif msg.msg_type == HM_ATTRIBUTE
            if attrs === EMPTY_READ_ATTRIBUTES
                attrs = ReadAttribute[read_attribute(cio, f)]
            else
                push!(attrs, read_attribute(cio, f))
            end
        elseif (msg.flags & 2^3) != 0
            throw(UnsupportedFeatureException())
        end
        seek(cio, endpos)
    end
    seek(cio, pmax)

    filter_id != 0 && !chunked_storage && throw(InvalidDataException("Compressed data must be chunked"))

    # Checksum
    end_checksum(cio) == jlread(io, UInt32) || throw(InvalidDataException("Invalid Checksum"))

    headersize = jlsizeof(ObjectStart) + size_size(sz) + sz + 4
    LoadedDataset(
        name, group, offset, headersize, data_offset, data_length,
        dataspace, datatype_class, datatype_offset, filter_id, attrs,
         storage_type,nothing, nothing)

end

function load_ds(ds::LoadedDataset)
    ds.parent.f.n_times_opened == 0 && throw(ArgumentError("file is closed"))

    read_data(ds.parent.f,
        ds.dataspace, 
        ds.datatype_class, 
        ds.datatype_offset, 
        ds.data_offset, 
        ds.data_length,
        ds.filter_id, 
        ds.header_offset, 
        ds.attrs)
end


function edit!(ds::LoadedDataset, data, wsession=JLDWriteSession())
    @assert ds.parent.f.writable "Cannot edit in read-only mode"

    odr = objodr(data)
    f = ds.parent.f
    io = f.io
    datatype_class = ds.datatype_class
    datatype_offset = ds.datatype_offset
    data_offset = ds.data_offset
    if datatype_class == typemax(UInt8) # Committed datatype
        rr = jltype(f, f.datatype_locations[h5offset(f, datatype_offset)])
    else
        seek(io, datatype_offset)
        @read_datatype io datatype_class dt begin
            rr = jltype(f, dt)
        end
    end

    wodr = typeof(rr).parameters[2]
    @assert wodr == odr "Types do not match $wodr (written) $odr (new)"
    @assert ds.dataspace.dataspace_type == DS_SCALAR
    seek(io, data_offset)
    write_data(io, f, data, odr, datamode(odr), wsession)

    # Update checksum for compact storage
    if ds.layout_class == LC_COMPACT_STORAGE
        offset = fileoffset(f, ds.header_offset)
        update_checksum(io, offset, offset+ds.header_size)
    end
    return data
end


function JLD2.update_checksum(io, start_offset::Int, checksum_offset)
    seek(io, start_offset)
    cio = begin_checksum_read(io)
    seek(cio, checksum_offset-4)
    seek(io, checksum_offset-4)
    jlwrite(io, end_checksum(cio))
end
