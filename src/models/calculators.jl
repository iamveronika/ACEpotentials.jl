
import EmpiricalPotentials 
import EmpiricalPotentials: SitePotential, 
                            cutoff_radius, 
                            eval_site, 
                            eval_grad_site, 
                            site_virial, 
                            PairList, 
                            get_neighbours, 
                            atomic_number

import AtomsCalculators
import AtomsCalculators: energy_forces_virial

using Folds, ChunkSplitters, Unitful, NeighbourLists, 
      Optimisers, LuxCore, ChainRulesCore 

using ComponentArrays: ComponentArray

import ChainRulesCore: rrule, NoTangent, ZeroTangent

using ObjectPools: release! 

struct ACEPotential{MOD} <: SitePotential
   model::MOD
end

# TODO: allow user to specify what units the model is working with

energy_unit(::ACEPotential) = 1.0u"eV"
distance_unit(::ACEPotential) = 1.0u"Å"
force_unit(V) = energy_unit(V) / distance_unit(V)
Base.zero(V::ACEPotential) =  zero(energy_unit(V))


# --------------------------------------------------------------- 
#   EmpiricalPotentials / SitePotential based implementation 
#
#   this currently doesn't know how to handle ps and st 
#   it assumes implicitly without checking that the model is 
#   storing its own parameters. 

cutoff_radius(V::ACEPotential{<: ACEModel}) = 
      maximum(x.rcut for x in V.model.rbasis.rin0cuts) * distance_unit(V)

eval_site(V::ACEPotential{<: ACEModel}, Rs, Zs, z0) = 
      evaluate(V.model, Rs, Zs, z0) * energy_unit(V)

eval_grad_site(V::ACEPotential{<: ACEModel}, Rs, Zs, z0) = 
      evaluate_ed(V.model, Rs, Zs, z0) * force_unit(V)


# --------------------------------------------------------------- 
#   manual implementation allowing parameters  
#   but basically copied from the EmpiricalPotentials implementation 

import JuLIP
import AtomsBase
using Unitful: ustrip
_ustrip(x) = ustrip(x)
_ustrip(x::ZeroTangent) = x

AtomsBase.atomic_number(at::JuLIP.Atoms, iat::Integer) = at.Z[iat]

function energy_forces_virial(
         at, V::ACEPotential{<: ACEModel}, ps, st;
         domain   = 1:length(at), 
         executor = ThreadedEx(),
         ntasks   = Threads.nthreads(),
         nlist    = JuLIP.neighbourlist(at, cutoff_radius(V)/distance_unit(V)),
         kwargs...
         )

   T = fl_type(V.model) # this is ACE specific 
   init_e() = zero(T) * energy_unit(V)
   init_f() = zeros(SVector{3, T}, length(at)) * force_unit(V)
   init_v() = zero(SMatrix{3, 3, T}) * energy_unit(V)

   # TODO: each task needs its own state if that is where  
   #       the temporary arrays will be stored? 
   #       but if we use bumper then there is no issue
   
   E_F_V = Folds.sum(collect(chunks(domain, ntasks)), 
                     executor;
                     init = [init_e(), init_f(), init_v()],
                     ) do (sub_domain, _)

      energy = init_e()
      forces = init_f()
      virial = init_v()

      for i in sub_domain
         Js, Rs, Zs, z0 = get_neighbours(at, V, nlist, i) 
         v, dv, st = evaluate_ed(V.model, Rs, Zs, z0, ps, st)
         energy += v * energy_unit(V)
         forces[Js] -= (dv * force_unit(V))
         forces[i]  += sum(dv) * force_unit(V)
         virial += JuLIP.Potentials.site_virial(dv, Rs) * energy_unit(V)
         release!(Js); release!(Rs); release!(Zs)
      end
      [energy, forces, virial]
   end
   return (energy = E_F_V[1], forces = E_F_V[2], virial = E_F_V[3])
end


# this implements the pullback of the energy_forces_virial function
# w.r.t. to the parameters only!!
# we should implement similar pullback helpers for forces and remove them 
# from the function below to be re-used broadly. 

# function site_virial(dV::AbstractVector{SVector{3, T1}}, 
#                      Rs::AbstractVector{SVector{3, T2}}) where {T1, T2}
#    T = promote_type(T1, T2)
#    return sum( dVj * rj' for (dVj, rj) in zip(dV, Rs), 
#                init = zero(SMatrix{3, 3, T}) )
# end

# function pullback_sitevirial_dV(Δ, Rs) 
#    #   Δ : virial  =  ∑_j dVj' * Δ * rj 
#    #   ∂_dVj (Δ : virial) = Δ * rj
#    return [ Δ * rj for rj in Rs ]
# end

function pullback_EFV(Δefv, 
               at, V::ACEPotential{<: ACEModel}, ps, st;
               domain   = 1:length(at), 
               executor = ThreadedEx(),
               ntasks   = Threads.nthreads(),
               nlist    = JuLIP.neighbourlist(at, cutoff_radius(V)/distance_unit(V)),
               kwargs...
               )

   T = fl_type(V.model) 
   ps_vec, _restruct = destructure(ps)
   TP = promote_type(eltype(ps_vec), T) 

   # We resolve the pullback through the summation-over-sites manually, e.g., 
   # E = ∑_i E_i 
   #     ∂ (Δe * E) = ∑_i ∂( Δe * E_i ) 

   # TODO : There is a lot of ustrip hacking which implicitly 
   #        assumes that the loss is dimensionless and that the 
   #        gradient w.r.t. parameters therefore must also be dimensionless 

   g_vec = Folds.sum(collect(chunks(domain, ntasks)), 
                     executor;
                     init = zeros(TP, length(ps_vec)),
                     ) do (sub_domain, _)

      g_loc = zeros(TP, length(ps_vec))
      for i in sub_domain                     
         Js, Rs, Zs, z0 = get_neighbours(at, V, nlist, i)
                           
         Δei = _ustrip(Δefv.energy)

         # them adjoint for dV needs combination of the virial and forces pullback
         Δdi = [ _ustrip.(Δefv.virial * rj) for rj in Rs ]
         for α = 1:length(Js) 
            # F[Js[α]] -= dV[α], F[i] += dV[α] 
            # ∂_dvj { Δf[Js[α]] * F[Js[α]] } -> 
            Δdi[α] -= _ustrip.( Δefv.forces[Js[α]] )
            Δdi[α] += _ustrip.( Δefv.forces[i]     )
         end

         # now we can apply the pullback through evaluate_ed 
         # (maybe this needs to be renamed, it sounds a bit cryptic) 
         if eltype(Δdi) == ZeroTangent 
            g_nt = grad_params(V.model, Rs, Zs, z0, ps, st)[2]
            mult = Δei
         else 
            g_nt = pullback_2_mixed(Δei, Δdi, V.model, Rs, Zs, z0, ps, st)
            mult = one(TP)
         end

         release!(Js); release!(Rs); release!(Zs)
         
         # convert it back to a vector so we can accumulate it in the sum. 
         # this is quite bad - in the call to pullback_2_mixed we just 
         # converted it from a vector to a named tuple. We need to look into 
         # using something like ComponentArrays.jl to avoid this.
         g_loc += destructure(g_nt)[1] * mult
      end
      g_loc
   end

   return _restruct(g_vec)
end                


function rrule(::typeof(energy_forces_virial), 
               at, V::ACEPotential{<: ACEModel}, ps, st;
               domain   = 1:length(at), 
               executor = ThreadedEx(),
               ntasks   = Threads.nthreads(),
               nlist    = JuLIP.neighbourlist(at, cutoff_radius(V)/distance_unit(V)),
               kwargs...
               )

   # TODO : analyze this code flow carefully and see if we can 
   #        re-use any of the computations done in the EFV evaluation                 
   EFV = energy_forces_virial(at, V, ps, st; 
                              domain = domain, 
                              executor = executor, 
                              ntasks = ntasks, 
                              nlist = nlist, 
                              kwargs...)

   return EFV, Δefv -> ( NoTangent(), NoTangent(), NoTangent(), 
                       pullback_EFV(Δefv, at, V, ps, st; 
                                    domain = domain, 
                                    executor = executor, 
                                    ntasks = ntasks, 
                                    nlist = nlist, 
                                    kwargs...), NoTangent() )
end
