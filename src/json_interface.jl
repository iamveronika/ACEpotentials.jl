import ArgParse 

import .ACE1compat
using ACEfit

# === nt utilities ===
function create_namedtuple(dict)
   return NamedTuple{Tuple(Symbol.(keys(dict)))}(values(dict))
end

function nested_namedtuple_to_dict(nt)
   return Dict(k => isa(v, NamedTuple) ? nested_namedtuple_to_dict(v) : v for (k, v) in pairs(nt))
end
 
function _sanitize_arg(arg)
   if isa(arg, Vector)  
      return _sanitize_arg.(tuple(arg...))
   elseif isa(arg, String)
      return Symbol(arg)
   else
      return arg
   end
end

function _sanitize_dict(dict)
   return Dict(Symbol(key) => _sanitize_arg(dict[key]) for key in keys(dict))
end

##

# === make fits === 
function make_model(model_dict::Dict)
   if model_dict["model_name"] == "ACE1"
      model_nt = _sanitize_dict(model_dict)
      return ACE1compat.ace1_model(; model_nt...)
   else
      error("Unknown model: $(fitting_params["model"]["model_name"]). This function only supports 'ACE1'.")
   end
end

# chho: make this support other solvers
function make_solver(solver_dict::Dict)
   if solver_dict["name"] == "BLR"
      params_nt = _sanitize_dict(solver_dict["param"])
      return ACEfit.BLR(; params_nt...)
   elseif solver_dict["name"] == "LSQR"
      params_nt = _sanitize_dict(solver_dict["param"])
      return ACEfit.LSQR(; params_nt...)
   else
      error("Not implemented.")
   end
end

# function make_prior(model, prior_dict::Dict)
#    if prior_dict["name"] === "algebraic"
#       return ACEpotentials.Models.algebraic_smoothness_prior(model.basis; p = prior_dict["param"])
#    else
#       error("Not implemented.")
#    end
# end


function copy_runfit(dest)
   script_path = joinpath(@__DIR__(), "..", "scripts")
   runfit_orig = joinpath(script_path, "runfit.jl")
   exjson_orig = joinpath(script_path, "example_params.json")
   runfit_dest = joinpath(dest, "runfit.jl")
   exjson_dest = joinpath(dest, "example_params.json")
   run(`cp $runfit_orig $runfit_dest`)
   run(`cp $exjson_orig $exjson_dest`)
   return nothing
end



function save_model(model, filename; 
                    make_model_args = nothing, 
                    errors = nothing, 
                    verbose = true, 
                    meta = Dict(), )

   D = Dict("model_parameters" => model.ps, 
            "meta" => meta)

   if isnothing(make_model_args) 
      if verbose
         @warn("Only model parameters are saved but no information to reconstruct the model.")
      end
   else 
      D["make_model_args"] = make_model_args
   end

   if !isnothing(errors)
      D["errors"] = errors
   end

   open(filename, "w") do io
       write(io, JSON.json(D, 3))
   end

   if verbose
      @info "Results saved to file: $filename"
   end
end
