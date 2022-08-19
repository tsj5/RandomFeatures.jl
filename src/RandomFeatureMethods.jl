module RandomFeatureMethods

import StatsBase: sample
import RandomFeatures.Utilities: Decomposition 
import RandomFeatures.Utilities: batch_generator, linear_solve, get_decomposition_is_inverse, get_decomposition

using
    LinearAlgebra,
    RandomFeatures.Features,
    EnsembleKalmanProcesses.DataContainers

export
    RandomFeatureMethod,
    Fit,
    get_random_feature,
    get_batch_sizes,
    get_regularization,
    sample,
    get_feature_factors,
    get_coeffs,
    fit!,
    predict,
    predictive_mean,
    predictive_cov


struct RandomFeatureMethod
    rf::RandomFeature
    batch_sizes::Dict #keys "train", "test" , "features"
    regularization::Real
end

get_random_feature(rfm::RandomFeatureMethod) = rfm.rf
get_batch_sizes(rfm::RandomFeatureMethod) = rfm.batch_sizes
get_regularization(rfm::RandomFeatureMethod) = rfm.regularization
sample(rfm::RandomFeatureMethod) = sample(rfm.rf)

struct Fit
    feature_factors::Decomposition
    coeffs::AbstractVector
end

get_feature_factors(f::Fit) = f.feature_factors
get_coeffs(f::Fit) = f.coeffs


function fit!(
    rfm::RandomFeatureMethod,
    input_output_pairs::PairedDataContainer,
    decomposition_type::AbstractString = "svd"
)

    (input,output) = get_data(input_output_pairs)
    output_dim = size(output,1) # for scalar features this is 1

    train_batch_size = get_batch_size(rfm, "train")
    rf = get_random_feature(rfm)
    n_features = get_n_features(rf)
    #data are columns, batch over samples
    batch_input = batch_generator(input, train_batch_size, dims=2) # input_dim x batch_size
    batch_output = batch_generator(output, train_batch_size, dims=2) # output_dim x batch_size

    PhiTY = zeros(n_features,output_dim)
    PhiTPhi = zeros(n_features, n_features)
    
    for (ib,ob) in zip(batch_input, batch_output)
        batch_feature = build_features(rf, ib) # batch_size x n_features
        PhiTY += permutedims(batch_feature,(2,1)) * ob
        PhiTPhi +=  permutedims(batch_feature,(2,1)) * batch_feature 
    end
    PhiTPhi /= n_features

    # solve the linear system
    # (PhiTPhi + lambda * I) * beta = PhiTY

    lambda = get_regularization(rfm)
    if lambda == 0
       feature_factors = Decomposition(PhiTPhi, method="pinv")
    else
        feature_factors = Decomposition(PhiTPhi + lambda * I, method=decomposition_type)
    end
    coeffs = linear_solve(feature_factors, PhiTY)

    return Fit(Decomposition, coeffs)   
end

function predict(rfm::RandomFeatureMethod, fit::Fit, new_inputs::DataContainer)
    pred_mean = predictive_mean(rfm, fit, new_inputs)
    pred_cov,_ = predictive_cov(rfm, fit, new_inputs)
    return pred_mean, pred_cov
end

function predictive_mean(rfm::RandomFeatureMethod, fit::Fit, new_inputs::DataContainer)

    inputs = get_data(new_inputs)
    outputs = zeros(1,size(inputs,2))

    test_batch_size = get_batch_size(rfm, "test")
    features_batch_size = get_batch_size(rfm, "features")
    rf = get_random_feature(rfm)

    n_features = get_n_features(rf)

    coeffs = get_feature_coeffs(fit) 
    
    batch_inputs = batch_generator(inputs, test_batch_size, dims=2) # input_dim x batch_size
    batch_outputs = batch_generator(outputs, test_batch_size, dims=2) # input_dim x batch_size
    batch_coeffs = batch_generator(coeffs, features_batch_size)
    batch_feature_idx = batch_generator(collect(1:n_features), features_batch_size)

    for (ib, ob) in zip(batch_inputs, batch_outputs)
        for (cb, fb_i) in zip(batch_coeffs, batch_feature_idx)
            features = build_features(rf, ib, fb_i) # n_samples x n_features
            ob += features * cb / n_features # n_samples x 1
        end
    end
    
    return outputs
end

function predictive_cov(rfm::RandomFeatureMethod, fit::Fit, new_inputs::DataContainer)
    # unlike in mean case, we must perform a linear solve for coefficients at every test point.
    # thus we return both the covariance and the input-dep coefficients
    # note the covariance here is a posterior variance in 1d outputs, it is not the posterior covariance
    
    inputs = get_data(new_inputs)
    
    test_batch_size = get_batch_size(rfm, "test")
    features_batch_size = get_batch_size(rfm, "features")
    rf = get_random_feature(rfm)
    lambda = get_regularization(rfm)
    
    n_features = get_n_features(rf)

    coeffs = get_feature_coeffs(fit) 
    PhiTPhi_reg_factors = get_feature_factors(fit)
    PhiTPhi_reg = get_full_matrix(PhiTPhi_reg_factors)
    PhiTPhi = PhiTPhi_reg - lambda * I
    
    coeff_outputs = zeros(n_features,size(inputs,2))
    cov_outputs = zeros(1,size(inputs,2)) # 
    
    batch_inputs = batch_generator(inputs, test_batch_size, dims=2) # input_dim x batch_size
    batch_outputs = batch_generator(outputs, test_batch_size, dims=2) # 1 x batch_size
    batch_coeff_outputs = batch_generator(coeff_outputs, test_batch_size, dims=2)
    
    for (ib, ob, cob) in zip(batch_inputs, batch_outputs, batch_coeff_outputs)
        features = build_features(rf, ib) # bsize x n_features  
        rhs = PhiTPhi * permutedims(features, (2,1)) # n_features x bsize
        c_tmp = linear_solve(PhiTPhi_reg_factors, rhs) # n_features x bsize
        cob += c_tmp
        # here we do a pointwise calculation of var (1d output) for each test point
        ob += sum(permutedims(features,(2,1)) .* (permutedims(features,(2,1)) - c_tmp), dims=1) / n_features 
    end
    return cov_outputs, coeff_outputs
end

function posterior_cov(rfm::RandomFeatureMethod, u_input, v_input)
    
end

function get_optimizable_hyperparameters(rfm::RandomFeatureMethod)
    
end

function set_optimized_hyperparameters(rfm::RandomFeatureMethod, optimized_hyperparameters)

end

function evaluate_hyperparameter_cost(rfm::RandomFeatureMethod, input_data, output_data)

end



end # module