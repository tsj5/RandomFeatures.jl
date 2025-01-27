# Example to learn hyperparameters of simple 1d-1d regression example.
# This example matches test/Methods/runtests.jl testset: "Fit and predict: 1D -> 1D"
# The (approximate) optimal values here are used in those tests.


using StableRNGs
using Distributions
using StatsBase
using LinearAlgebra
using Random


using EnsembleKalmanProcesses
const EKP = EnsembleKalmanProcesses

using EnsembleKalmanProcesses.ParameterDistributions
using EnsembleKalmanProcesses.DataContainers

using RandomFeatures.Samplers
using RandomFeatures.Features
using RandomFeatures.Methods
using RandomFeatures.Utilities

seed = 2024
ekp_seed = 99999
rng = StableRNG(seed)

## Functions of use
function RFM_from_hyperparameters(
    rng::AbstractRNG,
    l::Union{Real,AbstractVecOrMat},
    s::Real,
    regularizer::Real,
    n_features::Int,
    batch_sizes::Dict,
)

    μ_c = 0.0
    if isa(l,Real)
        σ_c = fill(l,input_dim)
    elseif isa(l,AbstractVector)
        if length(l) == 1
            σ_c = fill(l[1],input_dim)
        else
            σ_c = l
        end
    else isa(l,AbstractMatrix)
        σ_c = l[:,1]
    end

    pd = ParameterDistribution(
        Dict(
            "distribution" => VectorOfParameterized(map(sd -> Normal(μ_c,sd),σ_c)),
            "constraint" => repeat([no_constraint()],input_dim),
            "name" => "xi",
        ),
    )
    feature_sampler = FeatureSampler(pd, rng=rng)
    # Learn hyperparameters for different feature types
    
    sf = ScalarFourierFeature(
        n_features,
        feature_sampler,
        hyper_fixed = Dict("sigma" => s)
    )
    return RandomFeatureMethod(sf, regularization=regularizer)
end


function calculate_cost(
    rng::AbstractRNG,
    l::Union{Real,AbstractVecOrMat},
    s::Real,
    noise_sd::Real,
    n_features::Int,
    batch_sizes::Dict,
    io_pairs::PairedDataContainer,
    n_perm::Int,
)
    regularizer = noise_sd^2
    n_train = Int(floor(0.8*size(get_inputs(io_pairs),2))) # 80:20 train test
    n_test = size(get_inputs(io_pairs),2) - n_train
    costs = zeros(n_perm)
    for i in 1:n_perm
        # split data into train/test randomly
        permute_idx = shuffle(rng,collect(1:n_train+n_test))
        train_idx = permute_idx[1:n_train]
        itrain = get_inputs(io_pairs)[:,train_idx]
        otrain = get_outputs(io_pairs)[:,train_idx]
        io_train_cost = PairedDataContainer(itrain,otrain)
        test_idx = permute_idx[n_train+1:end]       
        itest = get_inputs(io_pairs)[:,test_idx]
        otest = get_outputs(io_pairs)[:,test_idx]
        
        #calculate the cost for the training permutation, and sample of features
        rfm = RFM_from_hyperparameters(rng, l, s, regularizer, n_features, batch_sizes)
        fitted_features = fit(rfm, io_train_cost, decomposition_type= "qr")
        coeffs = get_coeffs(fitted_features) 

        #batch test data
        test_batch_size = get_batch_size(rfm, "test")
        
        batch_inputs = batch_generator(itest, test_batch_size, dims=2) # input_dim x batch_size
        batch_outputs = batch_generator(otest, test_batch_size, dims=2) # input_dim x batch_size

        residual = zeros(1)
        for (ib,ob) in zip(batch_inputs, batch_outputs)
            residual[1] += 1/noise_sd^2* sum((ob - predictive_mean(rfm, fitted_features, DataContainer(ib))).^2)
        end
        test_cost = 0.5 * residual[1]

        rkhs_cost = 0.5 * regularizer / n_features * dot(coeffs,coeffs)

        costs[i] = test_cost + rkhs_cost
    end
    return  1/n_perm * sum(costs)
        
end

function estimate_cost_covariance(
    rng::AbstractRNG,
    l::Union{Real,AbstractVecOrMat},
    s::Real,
    noise_sd::Real,
    n_features::Int,
    batch_sizes::Dict,
    io_pairs::PairedDataContainer, 
    n_samples::Int;
    n_perm::Int=4
)
    costs = zeros(n_samples)
    for i = 1:n_samples
        costs[i] = calculate_cost(
            rng,
            l,
            s,
            noise_sd,
            n_features,
            batch_sizes,
            io_pairs,
            n_perm)
    end
    #get var of cost here 1D
    println(mean(costs))
    return var(costs)
    
end

function calculate_ensemble_cost(
    rng::AbstractRNG,
    lvecormat::AbstractVecOrMat,
    s::Real,
    noise_sd::Real,
    n_features::Int,
    batch_sizes::Dict,
    io_pairs::PairedDataContainer;
    n_perm::Int=4
)
    if isa(lvecormat,AbstractVector)
        lmat = reshape(lvecormat,1,:)
    else
        lmat = lvecormat
    end
    N_ens = size(lmat,2)
    costs = zeros(N_ens)
    for i in collect(1:N_ens)
        l = lmat[:,i]
        costs[i] = calculate_cost(
            rng,
            l,
            s,
            noise_sd,
            n_features,
            batch_sizes,
            io_pairs,
            n_perm)
    end
    
    return reshape(costs,1,:)

end




## Begin Script, define problem setting

input_dim = 10
ftest_nd_to_1d(x::AbstractMatrix) = mapslices(column -> cos(2*pi*norm(column)), x, dims=1)

n_data = 500
x = rand(rng, Uniform(-3,3), (input_dim, n_data))
noise_sd = 0.01
noise = rand(rng, Normal(0,noise_sd), (1,n_data))

y = ftest_nd_to_1d(x) + noise
io_pairs = PairedDataContainer(x, y) 

## Define Hyperpriors for EKP

#μ_l = 10.0
#σ_l = 10.0
#unif in all directions
#prior_lengthscale = constrained_gaussian("lengthscale", μ_l, σ_l, 0.0, Inf)

#non-unif
comp_μ_l = log(10)
comp_σ_l = 1
prior_lengthscale = ParameterDistribution(
    Dict(
        "distribution" => VectorOfParameterized(repeat([Normal(comp_μ_l,comp_σ_l)],input_dim)),
        "constraint" => repeat([bounded_below(0.0)],input_dim),
        "name" => "lengthscale",
    )
)


μ_s = 1.0               

#priors = combine_distributions([prior_lengthscale, prior_scaling])
priors = prior_lengthscale

# estimate the noise from running many RFM sample costs at the mean values
batch_sizes = Dict("train" => 200, "test" => 200, "feature" => 200)
n_samples = 100
n_features = 1000
n_perm = 4
Γ = estimate_cost_covariance(
    rng,
    exp(comp_μ_l), # take mean values
    μ_s, # take mean values
    noise_sd,
    n_features,
    batch_sizes,
    io_pairs,
    n_samples,
    n_perm=n_perm
)
Γ = reshape([Γ], 1, 1) # 1x1 matrix
println("noise in observations: ", Γ)
# Create EKI
N_ens = 50
N_iter = 20

initial_params = construct_initial_ensemble(priors, N_ens; rng_seed = ekp_seed)
optimal_cost = [0.0]
ekiobj = EKP.EnsembleKalmanProcess(initial_params, optimal_cost, Γ, Inversion())
err = zeros(N_iter)
for i in 1:N_iter

    #get parameters:
    lvec = transform_unconstrained_to_constrained(priors, get_u_final(ekiobj))
    g_ens = calculate_ensemble_cost(
        rng,
        lvec,
        μ_s,
        noise_sd,
        n_features,
        batch_sizes,
        io_pairs,
        n_perm=n_perm
    )

    EKP.update_ensemble!(ekiobj, g_ens)
    err[i] = get_error(ekiobj)[end] #mean((params_true - mean(params_i,dims=2)).^2)
    println("Iteration: " * string(i) * ", Error: " * string(err[i])*", for mean-parameters" *string(mean(transform_unconstrained_to_constrained(priors, get_u_final(ekiobj)),dims=2)))
end

#println(transform_unconstrained_to_constrained(priors,mean(get_u_final(ekiobj),dims=2)))
# functions:

