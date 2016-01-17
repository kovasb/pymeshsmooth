from libcpp.vector cimport vector
from cython cimport view

cimport opensubdiv

cdef extern from "core.h" nogil:
    cdef struct FVarData:
        int *indices
        float *values
        int indice_size
        int channel_id
        int value_shape[2]

    cdef struct SubdiveDesc:
        int level
        int *dst_face_counts
        FVarData src_vertices;
        FVarData dst_vertices;
        vector[FVarData] src_fvar
        vector[FVarData] dst_fvar

    cdef opensubdiv.TopologyRefiner* create_refiner(opensubdiv.TopologyDescriptor &desc) except+
    cdef void refine_uniform(opensubdiv.TopologyRefiner* refiner, int level) except+
    cdef void populate_indices(opensubdiv.TopologyRefiner *refiner, SubdiveDesc &desc) except+
    cdef void subdivide_uniform(opensubdiv.TopologyRefiner *refiner, SubdiveDesc &desc) except+

cdef class Channel(object):
    cdef public float[:,:] values

cdef class VarChannel(Channel):
    def __init__(self, str name, float[:,:] values not None):
        self.values = values

cdef class FVarChannel(Channel):
    cdef public int[:] indices
    cdef int channel_id
    def __init__(self, str name,
                       int[:] indices not None,
                       float[:,:] values not None):

            self.indices = indices
            self.values = values

    cdef FVarData get_description(self):
        cdef FVarData d;
        d.indices = &self.indices[0]
        d.values = &self.values[0][0]
        d.indice_size = len(self.indices)
        d.channel_id = self.channel_id
        d.value_shape[0] = self.values.shape[0]
        d.value_shape[1] = self.values.shape[1]
        return d


cdef class Mesh(object):
    cdef public int[:] face_counts
    cdef public FVarChannel vertices
    cdef public list vchannels
    cdef public list fvchannels

    def __init__(self, int[:] face_counts not None,
                       FVarChannel vertex_channel not None,
                           channels):

        self.face_counts = face_counts
        self.vertices = vertex_channel
        self.vchannels = []
        self.fvchannels = []
        for channel in channels:
            if isinstance(channel, FVarChannel):
                self.fvchannels.append(channel)
            elif isinstance(channel, VarChannel):
                self.vchannels.append(channel)
            else:
                raise TypeError("unkown channel type")

cdef class TopologyRefiner(object):
    cdef opensubdiv.TopologyRefiner *refiner
    cdef opensubdiv.TopologyDescriptor desc
    cdef vector[opensubdiv.TopologyDescriptor.FVarChannel] fvar_descriptors
    cdef Mesh mesh

    def __cinit__(self):
        self.refiner = NULL
    def __dealloc__(self):
        if self.refiner:
            del self.refiner

    def __init__(self, Mesh mesh not None):

        cdef FVarChannel fvchan

        self.mesh = mesh

        self.desc.numVertices = self.mesh.vertices.values.shape[0]
        self.desc.numFaces = self.mesh.face_counts.shape[0]
        self.desc.numVertsPerFace = &self.mesh.face_counts[0]
        self.desc.vertIndicesPerFace = &self.mesh.vertices.indices[0]

        self.fvar_descriptors.resize(len(self.mesh.fvchannels))

        for i, fvchan in enumerate(self.mesh.fvchannels):
            fvchan.channel_id = i
            self.fvar_descriptors[i].numValues = fvchan.indices.shape[0]
            self.fvar_descriptors[i].valueIndices = &fvchan.indices[0]

        self.desc.numFVarChannels = self.fvar_descriptors.size()
        self.desc.fvarChannels = &self.fvar_descriptors[0]
        with nogil:
            self.refiner = create_refiner(self.desc)

    cdef setup_dst_mesh(self, int level, Mesh mesh=None):
        cdef FVarChannel dst_fvchan
        cdef FVarChannel src_fvchan

        if not mesh:
            mesh = Mesh.__new__(Mesh)

        vert_count = self.refiner.GetLevel(level).GetNumVertices()
        face_count = self.refiner.GetLevel(level).GetNumFaces()
        indice_count = self.refiner.GetLevel(level).GetNumFaceVertices()

        mesh.face_counts = view.array(shape=(face_count, ), itemsize=sizeof(int), format="i")

        mesh.vertices =  FVarChannel.__new__(FVarChannel)
        mesh.vertices.indices = view.array(shape=(indice_count, ), itemsize=sizeof(int), format="i")
        vertex_element_size = self.mesh.vertices.values.shape[1]
        mesh.vertices.values = view.array(shape=(vert_count, vertex_element_size), itemsize=sizeof(float), format="f")
        mesh.fvchannels = []

        for i, src_fvchan in enumerate(self.mesh.fvchannels):
            dst_fvchan =  FVarChannel.__new__(FVarChannel)
            dst_fvchan.channel_id = src_fvchan.channel_id
            dst_fvchan.indices = view.array(shape=(indice_count, ), itemsize=sizeof(int), format="i")
            elements = src_fvchan.values.shape[1]
            size = self.refiner.GetLevel(level).GetNumFVarValues(i)
            dst_fvchan.values = view.array(shape=(size, elements), itemsize=sizeof(float), format="f")
            mesh.fvchannels.append(dst_fvchan)

        return mesh

    cdef void setup_subdiv_descriptor(self, int level, SubdiveDesc &desc, Mesh dst_mesh):
        cdef FVarChannel src_fvchan
        cdef FVarChannel dst_fvchan

        channel_count = len(self.mesh.fvchannels)
        desc.src_fvar.resize(channel_count)
        desc.dst_fvar.resize(channel_count)

        desc.level = level
        desc.dst_face_counts = &dst_mesh.face_counts[0]
        desc.dst_vertices = dst_mesh.vertices.get_description()
        desc.src_vertices = self.mesh.vertices.get_description()

        for i in range(channel_count):
            src_fvchan = self.mesh.fvchannels[i]
            dst_fvchan = dst_mesh.fvchannels[i]
            desc.src_fvar[i] = src_fvchan.get_description()
            desc.dst_fvar[i] = dst_fvchan.get_description()

    def refine_uniform(self, int level, Mesh mesh = None):

        if level != self.refiner.GetMaxLevel():
            with nogil:
                refine_uniform(self.refiner, level)

        mesh = self.setup_dst_mesh(level, mesh)

        cdef SubdiveDesc desc
        self.setup_subdiv_descriptor(level, desc, mesh)

        with nogil:
            subdivide_uniform(self.refiner, desc)
            populate_indices(self.refiner, desc)

        return mesh

