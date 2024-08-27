
using LinearAlgebra: I, Diagonal, UniformScaling

import ACE1x 
import ACE1x: ACE1Model, acemodel, _set_params!, smoothness_prior
import ACEpotentials.Models: ACEPotential

export acefit!, export2json, export2lammps


_get_Vref(model::ACE1Model) = model.Vref 
_get_Vref(model::ACEPotential) = model.model.Vref 


# import JuLIP: energy, forces, virial, cutoff
import ACE1.Utils: get_maxn


default_weights() = Dict("default"=>Dict("E"=>30.0, "F"=>1.0, "V"=>1.0))

function _make_prior(model::ACE1Model, smoothness, P)
   if P isa AbstractMatrix || P isa UniformScaling 
      return P 
   elseif smoothness isa Number 
      if smoothness >= 0 
         return ACE1x.smoothness_prior(model; p = smoothness)
      end
   end
end

function _make_prior(model::ACEpotentials.Models.ACEPotential, smoothness, P)
   if P isa AbstractMatrix || P isa UniformScaling 
      return P 
   elseif smoothness isa Number 
      if smoothness >= 0 
         return ACEpotentials.Models.algebraic_smoothness_prior(model.model; p = smoothness)
      else
         error("smoothness must be >= 0")
      end
   end
end

"""
`function acefit!(model, data; kwargs...)` : 
provides a simplified interface to fitting the 
parameters of a model specified via `ACE1Model`. The data should be 
provided as a collection (`AbstractVector`) of `JuLIP.Atoms` structures. 

Keyword arguments:
* `energy_key`, `force_key`, `virial_key` specify 
the label of the data to which the parameters will be fitted. 
* `weights` specifies the regression weights, default is 30 for energy, 1 for forces and virials
* `solver` specifies the lsq solver, default is `BLR` (BayesianLinearRegression)
* `smoothness` specifies the smoothness prior, i.e. how strongly damped 
   parameters corresponding to high polynomial degrees are; is 2.
* `prior` specifies a covariance of the prior, if `nothing` then a smoothness prior 
   is used, using the `smoothness` parameter 
* `repulsion_restraint` specifies whether to add artificial data to the training 
   set that effectively introduces a restraints encouraging repulsion 
   in the limit rij -> 0.
* `restraint_weight` specifies the weight of the repulsion restraint.
* `export_lammps` : path to a file to which the fitted potential will be exported 
   in a LAMMPS compatible format (yace)
* `export_json` : path to a file to which the fitted potential will be exported 
   in a JSON format, which can be read from Julia or Python
"""
function acefit!(model, raw_data;
                solver = ACEfit.BLR(),
                weights = default_weights(),
                energy_key = "energy", 
                force_key = "force", 
                virial_key = "virial", 
                smoothness = 4, 
                prior = nothing, 
                repulsion_restraint = false, 
                restraint_weight = 0.01, 
                export_lammps = nothing, 
                export_json = nothing, 
                verbose=true,
                kwargs...
   )


   data = map( raw_data ) do d
      AtomsData(d;
         energy_key = energy_key, 
         force_key=force_key, 
         virial_key = virial_key, 
         weights = weights, 
         v_ref = _get_Vref(model)
      )
   end

   if verbose
      assess_dataset(
         data;
         energy_key = energy_key, 
         force_key  = force_key, 
         virial_key = virial_key,
         kwargs...
      )
    end 

   if repulsion_restraint 
      if eltype(data) == AtomsData
         append!(data, _rep_dimer_data(model; weight = restraint_weight))
      else
         tmp = _rep_dimer_data_atomsbase(
            model; 
            weight = restraint_weight,
            energy_key = Symbol(energy_key),
            kwargs...
            )
         append!(data, tmp)
      end
   end
                  
   P = _make_prior(model, smoothness, prior)

   # actual assembly of the least square system 
   A, Y, W = ACEfit.assemble(data, model)

   Ap = Diagonal(W) * (A / P) 
   Y = W .* Y
   result = ACEfit.solve(solver, Ap, Y)
   coeffs = P \ result["C"]

   # TODO: make this nicer / remove the need for this ... 
   # dispatch setting of parameters 
   __set_params!(model::ACE1Model, coeffs) = ACE1x._set_params!(model, coeffs)
   __set_params!(model::ACEPotential, coeffs) = ACEpotentials.Models.set_parameters!(model, coeffs)
   
   __set_params!(model, coeffs)

   if haskey(result, "committee")
       co_coeffs = result["committee"]
       for i in 1:size(co_coeffs,2)
          co_coeffs[:,i] = P \ co_coeffs[:,i]
       end
       IP_com = ACE1.committee_potential(model.basis, coeffs, co_coeffs)
       (model.Vref != nothing) && (IP_com = JuLIP.MLIPs.SumIP(model.Vref, IP_com))
       # possibly too drastic to overwrite potential with committee potential?
       model.potential = IP_com
   end

   if export_lammps != nothing 
      error("automatic lammps export currently not supported")
      # export2lammps(export_lammps, model)
   end
   if export_json != nothing 
      error("automatic json export currently not supported")
      # export2json(export_json, model)
   end

   return model 
end


# TODO: removing this for now; we can revisit the new assembly implementation 
#       after a bit more testing. 
# function _dispatch_to_assebly(data::AbstractArray{AtomsData}, model; kwargs...)
#    # basis = model.basis 
#    # Vref = model.Vref 
#    if haskey(kwargs, :new_assembly) && kwargs[:new_assembly] == true
#       return ACEfit.assemble(data, basis; new_assembly=true)
#    else
#       return ACEfit.assemble(data, model)
#    end
# end



function linear_errors(raw_data::AbstractArray{<: Union{JuLIP.Atoms, AbstractSystem}}, model; 
                       energy_key = "energy", 
                       force_key = "force", 
                       virial_key = "virial", 
                       weights = default_weights(), 
                       verbose = true )
   data = [ AtomsData(at; energy_key = energy_key, force_key=force_key, 
                          virial_key = virial_key, weights = weights, 
                          v_ref = _get_Vref(model)) 
            for at in raw_data ]
   return linear_errors(data, model; verbose=verbose)
end


# ---------------- Implementation of the repulsion restraint 

function _rep_dimer_data_atomsbase(
   model;
   weight=0.01, 
   energy_key=:energy,
   group_key=:config_type,
   kwargs...
) 
   zz = model.basis.BB[1].zlist.list
   restraints = [] 
   B_pair = model.basis.BB[1] 
   if !isa(B_pair, ACE1.PolyPairBasis)
      error("repulsion restraints only implemented for PolyPairBasis")
   end

   for i = 1:length(zz), j = i:length(zz)
      z1, z2 = zz[i], zz[j]
      s1, s2 = chemical_symbol.((z1, z2))
      r0_est = 1.0   # could try to get this from the model meta-data 
      _rin = r0_est / 100  # can't take 0 since we'd end up with ∞ / ∞
      Pr_ij = B_pair.J[i, j]
      if !isa(Pr_ij, ACE1.OrthPolys.TransformedPolys)
         error("repulsion restraints only implemented for TransformedPolys")
      end
      envfun = Pr_ij.envelope 
      if !isa(envfun, ACE1.OrthPolys.PolyEnvelope)
         error("repulsion restraints only implemented for PolyEnvelope")
      end
      if !(envfun.p >= 0)
         error("repulsion restraints only implemented for PolyEnvelope with p >= 0")
      end
      env_rin = ACE1.evaluate(envfun, _rin)

      a1 = Atom(zz[1].z, zeros(3)u"Å")
      a2 = Atom(zz[2].z, [_rin, 0, 0]u"Å")
      cell = [ [_rin+1, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]u"Å"
      boundary_conditions = [DirichletZero(), DirichletZero(), DirichletZero()]
      data = FlexibleSystem([a1, a2], cell, boundary_conditions)
      
      # add weight to the structure
      kwargs =[
         energy_key => env_rin, 
         group_key  => "restraint", 
         :energy_weight => weight,
      ]
      data = FlexibleSystem(data; kwargs...)

      push!(restraints, data)
   end

   return restraints
end

function _rep_dimer_data(model; 
                         weight = 0.01
                         )
   zz = model.basis.BB[1].zlist.list
   restraints = [] 
   restraint_weights = Dict("restraint" => Dict("E" => weight, "F" => 0.0, "V" => 0.0))
   B_pair = model.basis.BB[1] 
   if !isa(B_pair, ACE1.PolyPairBasis)
      error("repulsion restraints only implemented for PolyPairBasis")
   end

   for i = 1:length(zz), j = i:length(zz)
      z1, z2 = zz[i], zz[j]
      s1, s2 = chemical_symbol.((z1, z2))
      r0_est = 1.0   # could try to get this from the model meta-data 
      _rin = r0_est / 100  # can't take 0 since we'd end up with ∞ / ∞
      Pr_ij = B_pair.J[i, j]
      if !isa(Pr_ij, ACE1.OrthPolys.TransformedPolys)
         error("repulsion restraints only implemented for TransformedPolys")
      end
      envfun = Pr_ij.envelope 
      if !isa(envfun, ACE1.OrthPolys.PolyEnvelope)
         error("repulsion restraints only implemented for PolyEnvelope")
      end
      if !(envfun.p >= 0)
         error("repulsion restraints only implemented for PolyEnvelope with p >= 0")
      end
      env_rin = ACE1.evaluate(envfun, _rin)
      at = at_dimer(_rin, z1, z2)
      set_data!(at, "REF_energy", env_rin)
      set_data!(at, "config_type", "restraint")
      #  AtomsData(atoms::Atoms; energy_key, force_key, virial_key, weights, v_ref, weight_key)
      dat = ACEpotentials.AtomsData(at, energy_key = "REF_energy", 
                                    force_key = "REF_forces", 
                                    virial_key = "REF_virial", 
                                    weights = restraint_weights, 
                                    v_ref = model.Vref)
      push!(restraints, dat) 
   end
   
   return restraints
end


"""
`export2lammps(pathtofile, model::ACE1Model)` : exports the potential to the
`.yace` format for use in LAMMPS.
"""
function export2lammps(pathtofile, model::ACE1Model)
   if pathtofile[end-4:end] != ".yace"
      @warn("the lammps potential filename should end in .yace")
   end
   export2lammps(pathtofile, model.potential)
end


# -----------------------------------------------------------
#  a temporary hack to quickly adapt the training weights \


# import ACEfit: assemble

# function assemble(raw_data::AbstractArray{JuLIP.Atoms}, model::ACE1Model; 
#                      weights = default_weights(),
#                      energy_key = "energy", 
#                      force_key = "force", 
#                      virial_key = "virial", 
#                      smoothness = 2, 
#                      prior = nothing, 
#                      repulsion_restraint = false, 
#                      restraint_weight = 0.01, 
#                      mode = :serial, 
#                      weights_only = false)

#    data = [ AtomsData(at; energy_key = energy_key, force_key=force_key, 
#                   virial_key = virial_key, weights = weights, 
#                   v_ref = model.Vref)  for at in raw_data ]

#    if repulsion_restraint 
#       append!(data, _rep_dimer_data(model, weight = restraint_weight))
#    end
        
#    if weights_only
#       W = ACEfit.assemble_weights(data)
#       return W
#    end 
      
#    A, Y, W = assemble(data, model.basis, mode)
#    return A, Y, W
# end
