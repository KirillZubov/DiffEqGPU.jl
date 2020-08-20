module DiffEqGPU

using KernelAbstractions, CUDA, DiffEqBase, LinearAlgebra, Distributed
using CUDA: CuPtr, CU_NULL, Mem, CuDefaultStream
using CUDA: CUBLAS
using ForwardDiff
import ZygoteRules
using RecursiveArrayTools

@kernel function gpu_kernel(@Const(f),du,@Const(u),@Const(p),@Const(t))
    i = @index(Global, Linear)
    @views @inbounds f(du[:,i],u[:,i],p[:,i],t)
end

@kernel function jac_kernel(@Const(f),J,@Const(u),@Const(p),@Const(t))
    i = @index(Global, Linear)-1
    section = 1 + (i*size(u,1)) : ((i+1)*size(u,1))
    @views @inbounds f(J[section,section],u[:,i+1],p[:,i+1],t)
end

@kernel function discrete_condition_kernel(@Const(condition),cur,@Const(u),@Const(t),@Const(p))
    i = @index(Global, Linear)
    @views @inbounds cur[i] = condition(u[:,i],t,FakeIntegrator(u[:,i],t,p[:,i]))
end

@kernel function discrete_affect!_kernel(@Const(affect!),cur,u,t,p)
    i = @index(Global, Linear)
    @views @inbounds cur[i] && affect!(FakeIntegrator(u[:,i],t,p[:,i]))
end

@kernel function continuous_condition_kernel(@Const(condition),out,@Const(u),@Const(t),@Const(p))
    i = @index(Global, Linear)
    @views @inbounds out[i] = condition(u[:,i],t,FakeIntegrator(u[:,i],t,p[:,i]))
end

@kernel function continuous_affect!_kernel(@Const(affect!),@Const(event_idx),u,t,p)
    i = @index(Global, Linear)
    @views @inbounds affect!(FakeIntegrator(u[:,i],t,p[:,i]))
end

maxthreads(::CPU) = 1024
maxthreads(::CUDADevice) = 256

function workgroupsize(backend, n)
    min(maxthreads(backend),n)
end

@kernel function W_kernel(@Const(jac), W, @Const(u), @Const(p), @Const(gamma), @Const(t))
    i = @index(Global, Linear)
    len = size(u,1)
    _W = @inbounds @view(W[:, :, i])
    @views @inbounds jac(_W,u[:,i],p[:,i],t)
    @inbounds for i in eachindex(_W)
        _W[i] = gamma*_W[i]
    end
    _one = one(eltype(_W))
    @inbounds for i in 1:len
        _W[i, i] = _W[i, i] - _one
    end
end

@kernel function Wt_kernel(@Const(jac), W, @Const(u), @Const(p), @Const(gamma), @Const(t))
    i = @index(Global, Linear)
    len = size(u,1)
    _W = @inbounds @view(W[:, :, i])
    @views @inbounds jac(_W,u[:,i],p[:,i],t)
    @inbounds for i in 1:len
        _W[i, i] = -inv(gamma) + _W[i, i]
    end
end

function cuda_lufact!(W)
    CUBLAS.getrf_strided_batched!(W, false)
    return nothing
end

function cpu_lufact!(W)
    len = size(W, 1)
    for i in 1:size(W,3)
        _W = @inbounds @view(W[:, :, i])
        generic_lufact!(_W, len)
    end
    return nothing
end

struct FakeIntegrator{uType,tType,P}
    u::uType
    t::tType
    p::P
end

abstract type EnsembleArrayAlgorithm <: DiffEqBase.EnsembleAlgorithm end
struct EnsembleCPUArray <: EnsembleArrayAlgorithm end
struct EnsembleGPUArray <: EnsembleArrayAlgorithm end

function DiffEqBase.__solve(ensembleprob::DiffEqBase.AbstractEnsembleProblem,
                 alg::Union{DiffEqBase.DEAlgorithm,Nothing},
                 ensemblealg::EnsembleArrayAlgorithm;
                 trajectories, batch_size = trajectories, kwargs...)

    num_batches = trajectories ÷ batch_size
    num_batches * batch_size != trajectories && (num_batches += 1)

    if num_batches == 1 && ensembleprob.reduction === DiffEqBase.DEFAULT_REDUCTION
       time = @elapsed sol = batch_solve(ensembleprob,alg,ensemblealg,1:trajectories;kwargs...)
       return DiffEqBase.EnsembleSolution(sol,time,true)
    end

    converged::Bool = false
    u = ensembleprob.u_init === nothing ? similar(batch_solve(ensembleprob,alg,ensemblealg,1:batch_size;kwargs...), 0) : ensembleprob.u_init

    if nprocs() == 1
        # While pmap works, this makes much better error messages.
        time = @elapsed begin
            sols = map(1:num_batches) do i
                if i == num_batches
                  I = (batch_size*(i-1)+1):trajectories
                else
                  I = (batch_size*(i-1)+1):batch_size*i
                end
                batch_data = batch_solve(ensembleprob,alg,ensemblealg,I;kwargs...)
                if ensembleprob.reduction !== DiffEqBase.DEFAULT_REDUCTION
                  u, _ = ensembleprob.reduction(u,batch_data,I)
                  return u
                else
                  batch_data
                end
            end
        end
    else
        time = @elapsed begin
            sols = pmap(1:num_batches) do i
                if i == num_batches
                  I = (batch_size*(i-1)+1):trajectories
                else
                  I = (batch_size*(i-1)+1):batch_size*i
                end
                x = batch_solve(ensembleprob,alg,ensemblealg,I;kwargs...)
                yield()
                if ensembleprob.reduction !== DiffEqBase.DEFAULT_REDUCTION
                  u, _ = ensembleprob.reduction(u,x,I)
                else
                  x
                end

            end
        end
    end

    if ensembleprob.reduction === DiffEqBase.DEFAULT_REDUCTION
        DiffEqBase.EnsembleSolution(hcat(sols...),time,true)
    else
        DiffEqBase.EnsembleSolution(sols[end], time, true)
    end
end

diffeqgpunorm(u::AbstractArray,t) = sqrt(sum(abs2, u)/length(u))
diffeqgpunorm(u::Union{AbstractFloat,Complex},t) = abs(u)
diffeqgpunorm(u::AbstractArray{<:ForwardDiff.Dual},t) = sqrt(sum(abs2∘ForwardDiff.value, u)/length(u))
diffeqgpunorm(u::ForwardDiff.Dual,t) = abs(ForwardDiff.value(u))

function batch_solve(ensembleprob,alg,ensemblealg,I;kwargs...)
    probs = [ensembleprob.prob_func(deepcopy(ensembleprob.prob),i,1) for i in I]
    @assert all(p->p.tspan == probs[1].tspan,probs)
    @assert !isempty(I)
    #@assert all(p->p.f === probs[1].f,probs)

    len = length(probs[1].u0)

    u0 = reduce(hcat,[probs[i].u0 for i in 1:length(I)])
    p  = reduce(hcat,[probs[i].p  for i in 1:length(I)])
    sol, solus = batch_solve_up(ensembleprob,probs,alg,ensemblealg,I,u0,p;kwargs...)
    [ensembleprob.output_func(DiffEqBase.build_solution(probs[i],alg,sol.t,solus[i],destats=sol.destats,retcode=sol.retcode),i)[1] for i in 1:length(probs)]
end

function batch_solve_up(ensembleprob,probs,alg,ensemblealg,I,u0,p;kwargs...)
    if ensemblealg isa EnsembleGPUArray
        u0 = CuArray(u0)
        p  = CuArray(p)
    end

    if DiffEqBase.has_jac(probs[1].f)
        jac_prototype = ensemblealg isa EnsembleGPUArray ?
                        cu(zeros(Float32,len,len,length(I))) :
                        zeros(Float32,len,len,length(I))
        if probs[1].f.colorvec !== nothing
            colorvec = repeat(probs[1].f.colorvec,length(I))
        else
            colorvec = repeat(1:length(probs[1].u0),length(I))
        end
    else
        jac_prototype = nothing
        colorvec = nothing
    end

    _callback = generate_callback(probs[1],length(I),ensemblealg)
    prob = generate_problem(probs[1],u0,p,jac_prototype,colorvec)

    sol  = solve(prob,alg; callback = _callback,merge_callbacks = false,
                 internalnorm=diffeqgpunorm,
                 kwargs...)

    us = Array.(sol.u)
    solus = [[@view(us[i][:,j]) for i in 1:length(us)] for j in 1:length(probs)]
    (sol,solus)
end

function seed_duals(x::Matrix{V},::Type{T},
                    ::ForwardDiff.Chunk{N} = ForwardDiff.Chunk(@view(x[:,1]),typemax(Int64)),
                    ) where {V,T,N}
  seeds = ForwardDiff.construct_seeds(ForwardDiff.Partials{N,V})
  duals = [ForwardDiff.Dual{T}(x[i,j],seeds[i]) for i in 1:size(x,1), j in 1:size(x,2)]
end

function extract_dus(us)
  jsize = size(us[1],1), ForwardDiff.npartials(us[1][1])
  utype = typeof(ForwardDiff.value(us[1][1]))
  map(1:size(us[1],2)) do k
      map(us) do u
        du_i = zeros(utype, jsize)
        for i in size(u,1)
          du_i[i, :] = ForwardDiff.partials(u[i,k])
        end
        du_i
      end
  end
end

struct DiffEqGPUAdjTag end

ZygoteRules.@adjoint function batch_solve_up(ensembleprob,probs,alg,ensemblealg,I,u0,p;kwargs...)
    pdual = seed_duals(p,DiffEqGPUAdjTag)
    u0 = convert.(eltype(pdual),u0)

    if ensemblealg isa EnsembleGPUArray
        u0     = CuArray(u0)
        pdual  = CuArray(pdual)
    end

    if DiffEqBase.has_jac(probs[1].f)
        jac_prototype = ensemblealg isa EnsembleGPUArray ?
                        cu(zeros(Float32,len,len,length(I))) :
                        zeros(Float32,len,len,length(I))
        if probs[1].f.colorvec !== nothing
            colorvec = repeat(probs[1].f.colorvec,length(I))
        else
            colorvec = repeat(1:length(probs[1].u0),length(I))
        end
    else
        jac_prototype = nothing
        colorvec = nothing
    end

    _callback = generate_callback(probs[1],length(I),ensemblealg)
    prob = generate_problem(probs[1],u0,pdual,jac_prototype,colorvec)

    sol  = solve(prob,alg; callback = _callback,merge_callbacks = false,
                 internalnorm=diffeqgpunorm,
                 kwargs...)

    us = Array.(sol.u)
    solus = [[ForwardDiff.value.(@view(us[i][:,j])) for i in 1:length(us)] for j in 1:length(probs)]
    function batch_solve_up_adjoint(Δ)
        dus = extract_dus(us)
        _Δ = Δ[2]
        adj = map(eachindex(dus)) do j
            sum(eachindex(dus[j])) do i
                J = dus[j][i]
                if _Δ[j] isa AbstractVector
                    v = _Δ[j][i]
                else
                    v = @view _Δ[j][i]
                end
                J'v
            end
        end
        (ntuple(_->nothing, 6)...,VectorOfArray(adj))
    end
    (sol,solus),batch_solve_up_adjoint
end

function generate_problem(prob::ODEProblem,u0,p,jac_prototype,colorvec)
    _f = let f=prob.f.f
        function (du,u,p,t)
            version = u isa CuArray ? CUDADevice() : CPU()
            wgs = workgroupsize(version,size(u,2))
            wait(version, gpu_kernel(version)(f,du,u,p,t;ndrange=size(u,2),
                                              dependencies=Event(version),
                                              workgroupsize=wgs))
        end
    end

    if DiffEqBase.has_jac(prob.f)
        _Wfact! = let jac=prob.f.jac
            function (W,u,p,gamma,t)
                iscuda = u isa CuArray
                version = iscuda ? CUDADevice() : CPU()
                wgs = workgroupsize(version,size(u,2))
                wait(version, W_kernel(version)(jac, W, u, p, gamma, t;
                                                ndrange=size(u,2),
                                                dependencies=Event(version),
                                                workgroupsize=wgs))
                iscuda ? cuda_lufact!(W) : cpu_lufact!(W)
            end
        end
        _Wfact!_t = let jac=prob.f.jac
            function (W,u,p,gamma,t)
                iscuda = u isa CuArray
                version = iscuda ? CUDADevice() : CPU()
                wgs = workgroupsize(version,size(u,2))
                wait(version, Wt_kernel(version)(jac, W, u, p, gamma, t;
                                                 ndrange=size(u,2),
                                                 dependencies=Event(version),
                                                 workgroupsize=wgs))
                iscuda ? cuda_lufact!(W) : cpu_lufact!(W)
            end
        end
    else
        _Wfact! = nothing
        _Wfact!_t = nothing
    end

    if DiffEqBase.has_tgrad(prob.f)
        _tgrad = let tgrad=prob.f.tgrad
            function (J,u,p,t)
                version = u isa CuArray ? CUDADevice() : CPU()
                wgs = workgroupsize(version,size(u,2))
                wait(version, gpu_kernel(version)(tgrad,J,u,p,t;
                                                  ndrange=size(u,2),
                                                  dependencies=Event(version),
                                                  workgroupsize=wgs))
            end
        end
    else
        _tgrad = nothing
    end

    f_func = ODEFunction(_f,Wfact = _Wfact!,
                        Wfact_t = _Wfact!_t,
                        #colorvec=colorvec,
                        jac_prototype = jac_prototype,
                        tgrad=_tgrad)
    prob = ODEProblem(f_func,u0,prob.tspan,p;
                      prob.kwargs...)
end

function generate_problem(prob::SDEProblem,u0,p,jac_prototype,colorvec)
    _f = let f=prob.f.f
        function (du,u,p,t)
            version = u isa CuArray ? CUDADevice() : CPU()
            wgs = workgroupsize(version,size(u,2))
            wait(version, gpu_kernel(version)(f,du,u,p,t;
                                              ndrange=size(u,2),
                                              dependencies=Event(version),
                                              workgroupsize=wgs))
        end
    end

    _g = let f=prob.f.g
        function (du,u,p,t)
            version = u isa CuArray ? CUDADevice() : CPU()
            wgs = workgroupsize(version,size(u,2))
            wait(version, gpu_kernel(version)(f,du,u,p,t;
                                              ndrange=size(u,2),
                                              dependencies=Event(version),
                                              workgroupsize=wgs))
        end
    end

    if DiffEqBase.has_jac(prob.f)
        _Wfact! = let jac=prob.f.jac
            function (W,u,p,gamma,t)
                iscuda = u isa CuArray
                version = iscuda ? CUDADevice() : CPU()
                wgs = workgroupsize(version,size(u,2))
                wait(version, W_kernel(version)(jac, W, u, p, gamma, t;
                                                ndrange=size(u,2),
                                                dependencies=Event(version),
                                                workgroupsize=wgs))
                iscuda ? cuda_lufact!(W) : cpu_lufact!(W)
            end
        end
        _Wfact!_t = let jac=prob.f.jac
            function (W,u,p,gamma,t)
                iscuda = u isa CuArray
                version = iscuda ? CUDADevice() : CPU()
                wgs = workgroupsize(version,size(u,2))
                wait(version, Wt_kernel(version)(jac, W, u, p, gamma, t;
                                                 ndrange=size(u,2),
                                                 dependencies=Event(version),
                                                 workgroupsize=wgs))
                iscuda ? cuda_lufact!(W) : cpu_lufact!(W)
            end
        end
    else
        _Wfact! = nothing
        _Wfact!_t = nothing
    end

    if DiffEqBase.has_tgrad(prob.f)
        _tgrad = let tgrad=prob.f.tgrad
            function (J,u,p,t)
                version = u isa CuArray ? CUDADevice() : CPU()
                wgs = workgroupsize(version,size(u,2))
                wait(version, gpu_kernel(version)(tgrad,J,u,p,t;
                                                  ndrange=size(u,2),
                                                  dependencies=Event(version),
                                                  workgroupsize=wgs))
            end
        end
    else
        _tgrad = nothing
    end

    f_func = SDEFunction(_f,_g,Wfact = _Wfact!,
                        Wfact_t = _Wfact!_t,
                        #colorvec=colorvec,
                        jac_prototype = jac_prototype,
                        tgrad=_tgrad)
    prob = SDEProblem(f_func,_g,u0,prob.tspan,p;
                      prob.kwargs...)
end

function generate_callback(prob,I,ensemblealg)
    if :callback ∉ keys(prob.kwargs)
        _callback = nothing
    elseif prob.kwargs[:callback] isa DiscreteCallback
        if ensemblealg isa EnsembleGPUArray
            cur = CuArray([false for i in 1:I])
        else
            cur = [false for i in 1:I]
        end
        _condition = prob.kwargs[:callback].condition
        _affect!   = prob.kwargs[:callback].affect!

        condition = function (u,t,integrator)
            version = u isa CuArray ? CUDADevice() : CPU()
            wgs = workgroupsize(version,size(u,2))
            wait(version, discrete_condition_kernel(version)(_condition,cur,u,t,integrator.p;
                                                             ndrange=size(u,2),
                                                             dependencies=Event(version),
                                                             workgroupsize=wgs))
            any(cur)
        end

        affect! = function (integrator)
            version = integrator.u isa CuArray ? CUDADevice() : CPU()
            wgs = workgroupsize(version,size(integrator.u,2))
            wait(version, discrete_affect!_kernel(version)(_affect!,cur,integrator.u,integrator.t,integrator.p;
                                                           ndrange=size(integrator.u,2),
                                                           dependencies=Event(version),
                                                           workgroupsize=wgs))
        end

        _callback = DiscreteCallback(condition,affect!,save_positions=prob.kwargs[:callback].save_positions)
    elseif prob.kwargs[:callback] isa ContinuousCallback
        _condition   = prob.kwargs[:callback].condition
        _affect!     = prob.kwargs[:callback].affect!
        _affect_neg! = prob.kwargs[:callback].affect_neg!

        condition = function (out,u,t,integrator)
            version = u isa CuArray ? CUDADevice() : CPU()
            wgs = workgroupsize(version,size(u,2))
            wait(version, continuous_condition_kernel(version)(_condition,out,u,t,integrator.p;
                                                               ndrange=size(u,2),
                                                               dependencies=Event(version),
                                                               workgroupsize=wgs))
            nothing
        end

        affect! = function (integrator,event_idx)
            version = integrator.u isa CuArray ? CUDADevice() : CPU()
            wgs = workgroupsize(version,size(integrator.u,2))
            wait(version, continuous_affect!_kernel(version)(_affect!,event_idx,integrator.u,integrator.t,integrator.p;
                                                             ndrange=size(integrator.u,2),
                                                             dependencies=Event(version),
                                                             workgroupsize=wgs))
        end

        affect_neg! = function (integrator,event_idx)
            version = integrator.u isa CuArray ? CUDADevice() : CPU()
            wgs = workgroupsize(version,size(integrator.u,2))
            wait(version, continuous_affect!_kernel(version)(_affect_neg!,event_idx,integrator.u,integrator.t,integrator.p;
                                                             ndrange=size(integrator.u,2),
                                                             dependencies=Event(version),
                                                             workgroupsize=wgs))
        end

        _callback = VectorContinuousCallback(condition,affect!,affect_neg!,I,save_positions=prob.kwargs[:callback].save_positions)
    end
    _callback
end

### GPU Factorization

struct LinSolveGPUSplitFactorize
    len::Int
    nfacts::Int
end
LinSolveGPUSplitFactorize() = LinSolveGPUSplitFactorize(0, 0)

function (p::LinSolveGPUSplitFactorize)(x,A,b,update_matrix=false;kwargs...)
    version = b isa CuArray ? CUDADevice() : CPU()
    copyto!(x, b)
    wgs = workgroupsize(version,p.nfacts)
    wait(version, ldiv!_kernel(version)(A,x,p.len,p.nfacts;
                                        ndrange=p.nfacts,
                                        dependencies=Event(version),
                                        workgroupsize=wgs))
    return nothing
end

function (p::LinSolveGPUSplitFactorize)(::Type{Val{:init}},f,u0_prototype)
    LinSolveGPUSplitFactorize(size(u0_prototype)...)
end

@kernel function ldiv!_kernel(W,u,@Const(len),@Const(nfacts))
    i = @index(Global, Linear)
    section = 1 + ((i-1)*len) : (i*len)
    _W = @inbounds @view(W[:, :, i])
    _u = @inbounds @view u[section]
    naivesolve!(_W, _u, len)
end

function __printjac(A, ii)
    @cuprintf "[%d, %d]\n" ii.offset1 ii.stride2
    @cuprintf "%d %d %d\n%d %d %d\n%d %d %d\n" ii[1, 1] ii[1, 2] ii[1, 3] ii[2, 1] ii[2, 2] ii[2, 3] ii[3, 1] ii[3, 2] ii[3, 3]
    @cuprintf "%2.2f %2.2f %2.2f\n%2.2f %2.2f %2.2f\n%2.2f %2.2f %2.2f" A[ii[1, 1]] A[ii[1, 2]] A[ii[1, 3]] A[ii[2, 1]] A[ii[2, 2]] A[ii[2, 3]] A[ii[3, 1]] A[ii[3, 2]] A[ii[3, 3]]
end

function generic_lufact!(A::AbstractMatrix{T}, minmn) where {T}
    m = n = minmn
    #@cuprintf "\n\nbefore lufact!\n"
    #__printjac(A, ii)
    #@cuprintf "\n"
    @inbounds for k = 1:minmn
        #@cuprintf "inner factorization loop\n"
        # Scale first column
        Akkinv = inv(A[k,k])
        for i = k+1:m
            #@cuprintf "L\n"
            A[i,k] *= Akkinv
        end
        # Update the rest
        for j = k+1:n, i = k+1:m
            #@cuprintf "U\n"
            A[i,j] -= A[i,k]*A[k,j]
        end
    end
    #@cuprintf "after lufact!"
    #__printjac(A, ii)
    #@cuprintf "\n\n\n"
    return nothing
end

struct MyL{T} # UnitLowerTriangular
    data::T
end
struct MyU{T} # UpperTriangular
    data::T
end

function naivesub!(A::MyU, b::AbstractVector, n)
    x = b
    @inbounds for j in n:-1:1
        xj = x[j] = A.data[j,j] \ b[j]
        for i in j-1:-1:1 # counterintuitively 1:j-1 performs slightly better
            b[i] -= A.data[i,j] * xj
        end
    end
    return nothing
end
function naivesub!(A::MyL, b::AbstractVector, n)
    x = b
    @inbounds for j in 1:n
        xj = x[j]
        for i in j+1:n
            b[i] -= A.data[i,j] * xj
        end
    end
    return nothing
end

function naivesolve!(A::AbstractMatrix, x::AbstractVector, n)
    naivesub!(MyL(A), x, n)
    naivesub!(MyU(A), x, n)
    return nothing
end

export EnsembleCPUArray, EnsembleGPUArray, LinSolveGPUSplitFactorize

end # module
