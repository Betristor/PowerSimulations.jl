struct AddVariableSpec
    variable_name::Symbol
    binary::Bool
    expression_name::Union{Nothing, Symbol}
    sign::Float64
    devices_filter_func::Union{Nothing, Function}
    initial_value_func::Union{Nothing, Function}
    lb_value_func::Union{Nothing, Function}
    ub_value_func::Union{Nothing, Function}
end

"""
Construct AddVariableSpec.

Accepts a single variable_name or a vector variable_names. One must be passed but not both.
"""
function AddVariableSpec(;
    variable_name,
    binary,
    expression_name = nothing,
    sign = 1.0,
    devices_filter_func = nothing,
    initial_value_func = nothing,
    lb_value_func = nothing,
    ub_value_func = nothing,
)
    return AddVariableSpec(
        variable_name,
        binary,
        expression_name,
        sign,
        devices_filter_func,
        initial_value_func,
        lb_value_func,
        ub_value_func,
    )
end

function AddVariableSpec(
    ::Type{<:T},
    ::Type{<:U},
    ::PSIContainer,
) where {T <: VariableType, U <: PSY.Component}
    error("AddVariableSpec is not implemented for $T / $U")
end

"""
Add variables to the PSIContainer for any component.
"""
function add_variables!(
    ::Type{T},
    psi_container::PSIContainer,
    devices::Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
) where {T <: VariableType, U <: PSY.Component}
    _add_variables!(psi_container, devices, AddVariableSpec(T, U, psi_container))
end

"""
Add variables to the PSIContainer for a service.
"""
function add_variables!(
    ::Type{T},
    psi_container::PSIContainer,
    service::U,
    contributing_devices::Vector{V},
) where {T <: VariableType, U <: PSY.Reserve, V <: PSY.Device}
    spec = AddVariableSpec(T, psi_container, service)
    _add_variables!(psi_container, contributing_devices, spec)
end

function _add_variables!(
    psi_container::PSIContainer,
    devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}},
    spec::AddVariableSpec,
) where {T <: PSY.Component}
    variable_name = spec.variable_name
    binary = spec.binary
    expression_name = spec.expression_name
    sign = spec.sign
    initial_value_func = spec.initial_value_func
    lb_value_func = spec.lb_value_func
    ub_value_func = spec.ub_value_func

    filter_func = nothing
    if isnothing(spec.devices_filter_func)
        if T <: PSY.Device
            filter_func = x -> PSY.get_available(x)
        end
    else
        filter_func = spec.devices_filter_func
    end
    if !isnothing(filter_func)
        devices = filter!(filter_func, collect(devices))
    end

    add_variable!(
        psi_container,
        devices,
        variable_name,
        binary,
        expression_name,
        sign;
        initial_value = initial_value_func,
        lb_value = lb_value_func,
        ub_value = ub_value_func,
    )
end

@doc raw"""
Adds a variable to the optimization model and to the affine expressions contained
in the psi_container model according to the specified sign. Based on the inputs, the variable can
be specified as binary.

# Bounds

``` lb_value_function <= varstart[name, t] <= ub_value_function ```

If binary = true:

``` varstart[name, t] in {0,1} ```

# LaTeX

``  lb \ge x^{device}_t \le ub \forall t ``

``  x^{device}_t \in {0,1} \forall t iff \text{binary = true}``

# Arguments
* psi_container::PSIContainer : the psi_container model built in PowerSimulations
* devices : Vector or Iterator with the devices
* var_name::Symbol : Base Name for the variable
* binary::Bool : Select if the variable is binary
* expression_name::Symbol : Expression_name name stored in psi_container.expressions to add the variable
* sign::Float64 : sign of the addition of the variable to the expression_name. Default Value is 1.0

# Accepted Keyword Arguments
* ub_value : Provides the function over device to obtain the value for a upper_bound
* lb_value : Provides the function over device to obtain the value for a lower_bound. If the variable is meant to be positive define lb = x -> 0.0
* initial_value : Provides the function over device to obtain the warm start value

"""
function add_variable!(
    psi_container::PSIContainer,
    devices::D,
    var_name::Symbol,
    binary::Bool,
    expression_name::Union{Nothing, Symbol} = nothing,
    sign::Float64 = 1.0;
    kwargs...,
) where {D <: Union{Vector{<:PSY.Component}, IS.FlattenIteratorWrapper{<:PSY.Component}}}
    @assert !isempty(devices)
    time_steps = model_time_steps(psi_container)
    variable = add_var_container!(
        psi_container,
        var_name,
        (PSY.get_name(d) for d in devices),
        time_steps,
    )

    lb_f = get(kwargs, :lb_value, nothing)
    init_f = get(kwargs, :initial_value, nothing)
    ub_f = get(kwargs, :ub_value, nothing)

    for t in time_steps, d in devices
        name = PSY.get_name(d)
        variable[name, t] = JuMP.@variable(
            psi_container.JuMPmodel,
            base_name = "$(var_name)_{$(name), $(t)}",
            binary = binary
        )

        !isnothing(ub_f) && JuMP.set_upper_bound(variable[name, t], ub_f(d))
        !isnothing(lb_f) && !binary && JuMP.set_lower_bound(variable[name, t], lb_f(d))
        !isnothing(init_f) && JuMP.set_start_value(variable[name, t], init_f(d))

        if !(isnothing(expression_name))
            bus_number = PSY.get_number(PSY.get_bus(d))
            add_to_expression!(
                get_expression(psi_container, expression_name),
                bus_number,
                t,
                variable[name, t],
                sign,
            )
        end
    end

    return

end

@doc raw"""
Adds a bounds to a variable in the optimization model.

# Bounds

``` bounds.min <= varstart[name, t] <= bounds.max  ```


# LaTeX

``  x^{device}_t >= bound^{min;} \forall t ``

``  x^{device}_t <= bound^{max} \forall t ``

# Arguments
* psi_container::PSIContainer : the psi_container model built in PowerSimulations
* bounds::DeviceRangeConstraintInfo : contains names and vector of min / max
* var_type::AbstractString : type of the variable
* T: type of the device

"""
function set_variable_bounds!(
    psi_container::PSIContainer,
    bounds::Vector{DeviceRangeConstraintInfo},
    var_type::AbstractString,
    ::Type{T},
) where {T <: PSY.Component}
    var = get_variable(psi_container, var_type, T)
    for t in model_time_steps(psi_container), bound in bounds
        _var = var[get_component_name(bound), t]
        JuMP.set_upper_bound(_var, bound.limits.max)
        JuMP.set_lower_bound(_var, bound.limits.min)
    end
end
