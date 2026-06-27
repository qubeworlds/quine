// Quine's Jolt extensions — Jolt C++ features the vendored JoltC C API doesn't
// wrap, exposed here as plain `extern "C"` functions and compiled INTO the same
// joltc library (natively via the module's C sources, on web via the emcc joltc
// object). This is the mechanism for reaching any Jolt feature on demand without
// editing the vendored binding; the first one exposed is soft-body cloth.
//
// The physics-system handle is taken as a `void*` — JoltC's `JPC_PhysicsSystem*`
// is a straight `reinterpret_cast` of `JPH::PhysicsSystem*` (see
// JoltPhysicsC.cpp `toJph`), and that same pointer is what `modules/physics`
// holds, so we cast it back here and call Jolt C++ directly.

#include <Jolt/Jolt.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/Body/BodyLock.h>
#include <Jolt/Physics/SoftBody/SoftBodyCreationSettings.h>
#include <Jolt/Physics/SoftBody/SoftBodySharedSettings.h>
#include <Jolt/Physics/SoftBody/SoftBodyMotionProperties.h>

#include <cstdint>

using namespace JPH;

extern "C" {

// Create a rectangular cloth soft body: an `nx × nz` grid in the XZ plane with
// world origin (ox,oy,oz) and `sp` spacing. `pinned` (nx*nz bytes, or null) marks
// kinematic (inverse-mass-0) vertices that stay where put. Structural, shear and
// bend springs + faces are generated. `layer` is the object layer (the engine's
// moving layer). Returns the BodyID value, or 0xFFFFFFFF on failure.
uint32_t quine_softbody_create_cloth(void *in_sys,
    uint32_t nx, uint32_t nz, float sp, float ox, float oy, float oz,
    const uint8_t *pinned, uint16_t layer, uint32_t iterations) {
    if (in_sys == nullptr || nx < 2 || nz < 2) return 0xFFFFFFFFu;
    PhysicsSystem *sys = reinterpret_cast<PhysicsSystem *>(in_sys);

    Ref<SoftBodySharedSettings> settings = new SoftBodySharedSettings();
    for (uint32_t j = 0; j < nz; j++)
        for (uint32_t i = 0; i < nx; i++) {
            SoftBodySharedSettings::Vertex v;
            v.mPosition = Float3(ox + (float)i * sp, oy, oz + (float)j * sp);
            v.mInvMass = (pinned != nullptr && pinned[j * nx + i]) ? 0.0f : 1.0f;
            settings->mVertices.push_back(v);
        }
    auto id = [nx](uint32_t i, uint32_t j) -> uint32_t { return j * nx + i; };
    auto edge = [&](uint32_t a, uint32_t b) {
        SoftBodySharedSettings::Edge e;
        e.mVertex[0] = a;
        e.mVertex[1] = b;
        e.mCompliance = 0.0f;
        settings->mEdgeConstraints.push_back(e);
    };
    for (uint32_t j = 0; j < nz; j++)
        for (uint32_t i = 0; i < nx; i++) {
            if (i + 1 < nx) edge(id(i, j), id(i + 1, j));               // structural
            if (j + 1 < nz) edge(id(i, j), id(i, j + 1));
            if (i + 1 < nx && j + 1 < nz) {                              // shear
                edge(id(i, j), id(i + 1, j + 1));
                edge(id(i + 1, j), id(i, j + 1));
            }
            if (i + 2 < nx) edge(id(i, j), id(i + 2, j));               // bend
            if (j + 2 < nz) edge(id(i, j), id(i, j + 2));
        }
    for (uint32_t j = 0; j + 1 < nz; j++)
        for (uint32_t i = 0; i + 1 < nx; i++) {
            SoftBodySharedSettings::Face f1;
            f1.mVertex[0] = id(i, j); f1.mVertex[1] = id(i, j + 1); f1.mVertex[2] = id(i + 1, j);
            settings->AddFace(f1);
            SoftBodySharedSettings::Face f2;
            f2.mVertex[0] = id(i + 1, j); f2.mVertex[1] = id(i, j + 1); f2.mVertex[2] = id(i + 1, j + 1);
            settings->AddFace(f2);
        }
    settings->CalculateEdgeLengths();
    settings->Optimize();

    SoftBodyCreationSettings cs(settings, RVec3::sZero(), Quat::sIdentity(), (ObjectLayer)layer);
    cs.mNumIterations = iterations < 1 ? 1 : iterations;
    cs.mUpdatePosition = false;  // pinned to the world frame → pins stay world-fixed
    cs.mAllowSleeping = false;   // keep simulating while the host lifts a corner
    BodyID bid = sys->GetBodyInterface().CreateAndAddSoftBody(cs, EActivation::Activate);
    return bid.GetIndexAndSequenceNumber();
}

// Read world-space vertex positions (3 floats each) into `out_xyz`. Returns the
// number written (≤ max_v).
uint32_t quine_softbody_read(void *in_sys, uint32_t in_id, float *out_xyz, uint32_t max_v) {
    if (in_sys == nullptr) return 0;
    PhysicsSystem *sys = reinterpret_cast<PhysicsSystem *>(in_sys);
    BodyLockRead lock(sys->GetBodyLockInterface(), BodyID(in_id));
    if (!lock.Succeeded()) return 0;
    const Body &body = lock.GetBody();
    const SoftBodyMotionProperties *mp = static_cast<const SoftBodyMotionProperties *>(body.GetMotionProperties());
    RMat44 com = body.GetCenterOfMassTransform();
    const Array<SoftBodyVertex> &verts = mp->GetVertices();
    uint32_t n = (uint32_t)verts.size();
    if (n > max_v) n = max_v;
    for (uint32_t k = 0; k < n; k++) {
        RVec3 w = com * verts[k].mPosition;
        out_xyz[k * 3 + 0] = (float)w.GetX();
        out_xyz[k * 3 + 1] = (float)w.GetY();
        out_xyz[k * 3 + 2] = (float)w.GetZ();
    }
    return n;
}

// Move a (kinematic / inverse-mass-0) vertex to a world position — the host drives
// this to lift / peel the sheet. `vidx` is the grid index j*nx + i.
void quine_softbody_set_vertex(void *in_sys, uint32_t in_id, uint32_t vidx, float wx, float wy, float wz) {
    if (in_sys == nullptr) return;
    PhysicsSystem *sys = reinterpret_cast<PhysicsSystem *>(in_sys);
    // Scope the body lock: ActivateBody() below takes the SAME per-body lock, and
    // Jolt's deadlock guard traps if a same-priority lock is still held. So write
    // the vertex under the lock, release it, THEN activate.
    {
        BodyLockWrite lock(sys->GetBodyLockInterface(), BodyID(in_id));
        if (!lock.Succeeded()) return;
        Body &body = lock.GetBody();
        SoftBodyMotionProperties *mp = static_cast<SoftBodyMotionProperties *>(body.GetMotionProperties());
        if (vidx >= (uint32_t)mp->GetVertices().size()) return;
        RMat44 inv = body.GetCenterOfMassTransform().Inversed();
        Vec3 local = Vec3(inv * RVec3(wx, wy, wz));
        SoftBodyVertex &v = mp->GetVertex(vidx);
        v.mPosition = local;
        v.mVelocity = Vec3::sZero();
    }
    sys->GetBodyInterface().ActivateBody(BodyID(in_id));
}

void quine_softbody_remove(void *in_sys, uint32_t in_id) {
    if (in_sys == nullptr) return;
    PhysicsSystem *sys = reinterpret_cast<PhysicsSystem *>(in_sys);
    BodyInterface &bi = sys->GetBodyInterface();
    bi.RemoveBody(BodyID(in_id));
    bi.DestroyBody(BodyID(in_id));
}

} // extern "C"
