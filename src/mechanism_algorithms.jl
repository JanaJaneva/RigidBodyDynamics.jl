transform_to_parent(state::MechanismState, frame::CartesianFrame3D) = get(state.transformsToParent[frame])
transform_to_root(state::MechanismState, frame::CartesianFrame3D) = get(state.transformsToRoot[frame])
relative_transform(state::MechanismState, from::CartesianFrame3D, to::CartesianFrame3D) = inv(transform_to_root(state, to)) * transform_to_root(state, from)

twist_wrt_world{X, M}(state::MechanismState{X, M}, body::RigidBody{M}) = get(state.twistsWrtWorld[body])
relative_twist{X, M}(state::MechanismState{X, M}, body::RigidBody{M}, base::RigidBody{M}) = -get(state.twistsWrtWorld[base]) + get(state.twistsWrtWorld[body])
function relative_twist(state::MechanismState, bodyFrame::CartesianFrame3D, baseFrame::CartesianFrame3D)
    twist = relative_twist(state, state.mechanism.bodyFixedFrameToBody[bodyFrame],  state.mechanism.bodyFixedFrameToBody[baseFrame])
    return Twist(bodyFrame, baseFrame, twist.frame, twist.angular, twist.linear)
end

bias_acceleration{X, M}(state::MechanismState{X, M}, body::RigidBody{M}) = get(state.biasAccelerations[body])

motion_subspace(state::MechanismState, joint::Joint) = get(state.motionSubspaces[joint])

spatial_inertia{X, M}(state::MechanismState{X, M}, body::RigidBody{M}) = get(state.spatialInertias[body])

crb_inertia{X, M}(state::MechanismState{X, M}, body::RigidBody{M}) = get(state.crbInertias[body])

function transform(state::MechanismState, point::Point3D, to::CartesianFrame3D)
    point.frame == to && return point # nothing to be done
    relative_transform(state, point.frame, to) * point
end

function transform(state::MechanismState, vector::FreeVector3D, to::CartesianFrame3D)
    vector.frame == to && return vector # nothing to be done
    relative_transform(state, vector.frame, to) * vector
end

function transform(state::MechanismState, twist::Twist, to::CartesianFrame3D)
    twist.frame == to && return twist # nothing to be done
    transform(twist, relative_transform(state, twist.frame, to))
end

function transform(state::MechanismState, wrench::Wrench, to::CartesianFrame3D)
    wrench.frame == to && return wrench # nothing to be done
    transform(wrench, relative_transform(state, wrench.frame, to))
end

function transform(state::MechanismState, accel::SpatialAcceleration, to::CartesianFrame3D)
    accel.frame == to && return accel # nothing to be done
    oldToRoot = transform_to_root(state, accel.frame)
    rootToOld = inv(oldToRoot)
    twistOfBodyWrtBase = transform(relative_twist(state, accel.body, accel.base), rootToOld)
    twistOfOldWrtNew = transform(relative_twist(state, accel.frame, to), rootToOld)
    oldToNew = inv(transform_to_root(state, to)) * oldToRoot
    return transform(accel, oldToNew, twistOfOldWrtNew, twistOfBodyWrtBase)
end


function subtree_mass{T}(base::Tree{RigidBody{T}, Joint})
    result = isroot(base) ? zero(T) : base.vertexData.inertia.mass
    for child in base.children
        result += subtree_mass(child)
    end
    return result
end
mass(m::Mechanism) = subtree_mass(tree(m))
mass(state::MechanismState) = mass(state.mechanism)

function center_of_mass{X, M, C}(state::MechanismState{X, M, C}, itr)
    frame = root_body(state.mechanism).frame
    com = Point3D(frame, zero(Vec{3, C}))
    mass = zero(C)
    for body in itr
        if !isroot(body)
            inertia = body.inertia
            com += inertia.mass * transform(state, Point3D(inertia.frame, convert(Vec{3, C}, inertia.centerOfMass)), frame)
            mass += inertia.mass
        end
    end
    com /= mass
    return com
end

center_of_mass(state::MechanismState) = center_of_mass(state, bodies(state.mechanism))

function geometric_jacobian{X, M, C}(state::MechanismState{X, M, C}, path::Path{RigidBody{M}, Joint})
    copysign = (motionSubspace::GeometricJacobian, sign::Int64) -> sign < 0 ? -motionSubspace : motionSubspace
    motionSubspaces = [copysign(motion_subspace(state, joint), sign)::GeometricJacobian{C} for (joint, sign) in zip(path.edgeData, path.directions)]
    return hcat(motionSubspaces...)
end

function relative_acceleration{X, M, V}(state::MechanismState{X, M}, body::RigidBody{M}, base::RigidBody{M}, v̇::Associative{Joint, Vector{V}})
    p = path(state.mechanism, base, body)
    J = geometric_jacobian(state, p)
    v̇path = vcat([v̇[joint]::Vector{V} for joint in p.edgeData]...)
    bias = -bias_acceleration(state, base) + bias_acceleration(state, body)
    return SpatialAcceleration(J, v̇path) + bias
end

kinetic_energy{X, M}(state::MechanismState{X, M}, body::RigidBody{M}) = kinetic_energy(spatial_inertia(state, body), twist_wrt_world(state, body))
function kinetic_energy{X, M}(state::MechanismState{X, M}, itr)
    return sum(body::RigidBody{M} -> kinetic_energy(state, body), itr)
end
kinetic_energy(state::MechanismState) = kinetic_energy(state, filter(b -> !isroot(b), bodies(state.mechanism)))

potential_energy{X, M, C}(state::MechanismState{X, M, C}) = -mass(state) * dot(convert(Vec{3, C}, state.mechanism.gravity), transform(state, center_of_mass(state), root_frame(state.mechanism)).v)

function mass_matrix{X, M, C}(state::MechanismState{X, M, C};
    ret = zeros(C, num_velocities(state.mechanism), num_velocities(state.mechanism)))

    for i = 2 : length(state.mechanism.toposortedTree)
        vi = state.mechanism.toposortedTree[i]

        # Hii
        jointi = vi.edgeToParentData
        if num_velocities(jointi) > 0
            bodyi = vi.vertexData
            irange = state.vRanges[jointi]
            Si = motion_subspace(state, jointi)
            Ii = crb_inertia(state, bodyi)
            F = crb_inertia(state, bodyi) * Si
            Hii = sub(ret, irange, irange)
            set_unsafe!(Hii, Si.angular' * F.angular + Si.linear' * F.linear)

            # Hji, Hij
            vj = vi.parent
            while (!isroot(vj))
                jointj = vj.edgeToParentData
                if num_velocities(jointj) > 0
                    jrange = state.vRanges[jointj]
                    Sj = motion_subspace(state, jointj)
                    @assert F.frame == Sj.frame
                    Hji = sub(ret, jrange, irange)
                    Hij = sub(ret, irange, jrange)
                    set_unsafe!(Hji, Sj.angular' * F.angular + Sj.linear' * F.linear)
                    Hij = Hji'
                end
                vj = vj.parent
            end
        end
    end
    ret
end

function momentum_matrix(state::MechanismState)
    hcat([crb_inertia(state, vertex.vertexData) * motion_subspace(state, vertex.edgeToParentData) for vertex in state.mechanism.toposortedTree[2 : end]]...)
end

function inverse_dynamics{X, M, V, W}(state::MechanismState{X, M}, v̇::Associative{Joint, Vector{V}} = NullDict{Joint, Vector{X}}();
    externalWrenches::Associative{RigidBody{M}, Wrench{W}} = NullDict{RigidBody{M}, Wrench{X}}())

    vertices = state.mechanism.toposortedTree
    T = promote_type(X, M, V, W)

    # compute spatial accelerations minus bias
    rootBody = root_body(state.mechanism)
    gravitational_accel = SpatialAcceleration(rootBody.frame, rootBody.frame, rootBody.frame, zero(Vec{3, T}), -convert(Vec{3, T}, state.mechanism.gravity))
    accels = Dict{RigidBody{M}, SpatialAcceleration{T}}(rootBody => gravitational_accel)
    sizehint!(accels, length(vertices))
    for i = 2 : length(vertices)
        vertex = vertices[i]
        body = vertex.vertexData
        joint = vertex.edgeToParentData
        S = motion_subspace(state, joint)
        v̇joint = get(v̇, joint, zeros(T, num_velocities(joint)))
        joint_accel = SpatialAcceleration(S, v̇joint)
        accels[body] = accels[vertex.parent.vertexData] + joint_accel
    end

    # add biases to accelerations and initialize joint wrenches with net wrenches computed using Newton Euler equations
    jointWrenches = Dict{RigidBody{M}, Wrench{T}}()
    sizehint!(jointWrenches, length(vertices) - 1)
    for i = 2 : length(vertices)
        vertex = vertices[i]
        body = vertex.vertexData
        joint = vertex.edgeToParentData

        Ṫbody = accels[body] + bias_acceleration(state, body)
        I = spatial_inertia(state, body)
        Tbody = twist_wrt_world(state, body)
        wrench = newton_euler(I, Ṫbody, Tbody)
        if haskey(externalWrenches, body)
            wrench = wrench - transform(state, externalWrenches[body], wrench.frame)
        end
        jointWrenches[body] = wrench
    end

    # project joint wrench to find torques, update parent joint wrench
    τ = Dict{Joint, Vector{T}}()
    sizehint!(τ, length(vertices) - 1)
    for i = length(vertices) : -1 : 2
        vertex = vertices[i]
        joint = vertex.edgeToParentData
        body = vertex.vertexData
        parentBody = vertex.parent.vertexData
        jointWrench = jointWrenches[body]
        S = motion_subspace(state, joint)
        τ[joint] = joint_torque(S, jointWrench)
        if !isroot(parentBody)
            jointWrenches[parentBody] = jointWrenches[parentBody] + jointWrench # action = -reaction
        end
    end
    τ
end

function dynamics{X, M, C, T, W}(state::MechanismState{X, M, C};
    torques::Associative{Joint, Vector{T}} = NullDict{Joint, Vector{X}}(),
    externalWrenches::Associative{RigidBody{M}, Wrench{W}} = NullDict{RigidBody{M}, Wrench{X}}(),
    massMatrix = zeros(C, num_velocities(state.mechanism), num_velocities(state.mechanism)))

    joints = keys(state.q)
    q̇ = velocity_to_configuration_derivative(state.q, state.v)
    c = torque_dict_to_vector(inverse_dynamics(state; externalWrenches = externalWrenches), joints)
    biasedTorques = isempty(torques) ? -c : torque_dict_to_vector(torques, joints) - c
    mass_matrix(state; ret = massMatrix)
    v̇ = velocity_vector_to_dict(massMatrix \ biasedTorques, joints)
    return q̇, v̇
end

# Convenience function that takes a Vector argument for the state and returns a Vector,
# e.g. for use with standard ODE integrators
# Note that preallocatedState is required so that we don't need to allocate a new
# MechanismState object every time this function is called
function dynamics{X}(stateVector::Vector{X}, preallocatedState::MechanismState{X}; kwargs...)
    set!(preallocatedState, stateVector)
    (q̇, v̇) = dynamics(preallocatedState; kwargs...)
    joints = keys(preallocatedState.q)
    return [configuration_dict_to_vector(q̇, joints); velocity_dict_to_vector(v̇, joints)]
end
