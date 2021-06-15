
struct TimeSeriesConstraintSpecInternal
    constraint_infos::Vector{DeviceTimeSeriesConstraintInfo}
    constraint_type::ConstraintType
    variable_type::VariableType
    bin_variable_type::Union{Nothing, VariableType}
    param_reference::Union{Nothing, UpdateRef}
    component_type::Type{<:PSY.Component}
end

function lazy_lb!(
    optimization_container::OptimizationContainer,
    inputs::TimeSeriesConstraintSpecInternal,
)
    time_steps = model_time_steps(optimization_container)
    names = [get_component_name(x) for x in inputs.constraint_infos]
    variable =
        get_variable(optimization_container, inputs.variable_type, inputs.component_type)
    con_lb = add_cons_container!(
        optimization_container,
        inputs.constraint_type,
        inputs.component_type,
        names,
        time_steps,
        meta = "lb",
    )

    for constraint_info in inputs.constraint_infos
        ci_name = get_component_name(constraint_info)
        if constraint_info.range.limits.min > -Inf &&
           !isempty(constraint_info.range.additional_terms_lb)
            con_lb[ci_name, :].data .= JuMP.AffExpr(0.0)
            continue
        end
        for t in time_steps
            expression_lb = JuMP.AffExpr(0.0, variable[ci_name, t] => 1.0)
            for val in constraint_info.range.additional_terms_lb
                JuMP.add_to_expression!(
                    expression_lb,
                    get_variable(optimization_container, val)[ci_name, t],
                    -1.0,
                )
            end
            lb_val = max(0.0, constraint_info.range.limits.min)
            con_lb[ci_name, t] =
                JuMP.@constraint(optimization_container.JuMPmodel, expression_lb >= lb_val)
        end
    end
    return
end

@doc raw"""
Constructs upper bound for given variable and time series data and a multiplier.

# Constraint

```variable[name, t] <= constraint_infos[name].multiplier * ts_data[name].timeseries[t] ```

# LaTeX

`` x_t \leq r^{val} r_t, \forall t ``
"""
function device_timeseries_ub!(
    optimization_container::OptimizationContainer,
    inputs::TimeSeriesConstraintSpecInternal,
)
    time_steps = model_time_steps(optimization_container)
    names = [get_component_name(x) for x in inputs.constraint_infos]
    variable =
        get_variable(optimization_container, inputs.variable_type, inputs.component_type)
    con_ub = add_cons_container!(
        optimization_container,
        inputs.constraint_type,
        inputs.component_type,
        names,
        time_steps,
        meta = "ub",
    )
    lazy_add_lb = false

    for constraint_info in inputs.constraint_infos
        ci_name = get_component_name(constraint_info)
        for t in time_steps
            expression_ub = JuMP.AffExpr(0.0, variable[ci_name, t] => 1.0)
            for val in constraint_info.range.additional_terms_ub
                JuMP.add_to_expression!(
                    expression_ub,
                    get_variable(optimization_container, val)[ci_name, t],
                )
            end
            con_ub[ci_name, t] = JuMP.@constraint(
                optimization_container.JuMPmodel,
                expression_ub <= constraint_info.multiplier * constraint_info.timeseries[t]
            )
        end
        if constraint_info.range.limits.min > -Inf ||
           !isempty(constraint_info.range.additional_terms_lb)
            lazy_add_lb = true
        end
    end

    @debug lazy_add_lb
    lazy_add_lb && lazy_lb!(optimization_container, inputs)

    return
end

@doc raw"""
Constructs lower bound for given variable subject to time series data and a multiplier.

# Constraint

``` constraint_infos[name].multiplier * ts_data[name].timeseries[t] <= variable[name, t] ```

# LaTeX

`` r^{val} r_t \leq x_t, \forall t ``

where (name, data) in range_data.
"""
function device_timeseries_lb!(
    optimization_container::OptimizationContainer,
    inputs::TimeSeriesConstraintSpecInternal,
)
    time_steps = model_time_steps(optimization_container)
    variable =
        get_variable(optimization_container, inputs.variable_type, inputs.component_type)
    names = [get_component_name(x) for x in inputs.constraint_infos]
    constraint = add_cons_container!(
        optimization_container,
        inputs.constraint_type,
        inputs.component_type,
        names,
        time_steps,
        meta = "lb",
    )

    for constraint_info in inputs.constraint_infos
        ci_name = get_component_name(constraint_info)
        for t in time_steps
            expression_lb = JuMP.AffExpr(0.0, variable[ci_name, t] => 1.0)
            for val in constraint_info.range.additional_terms_lb
                JuMP.add_to_expression!(
                    expression_lb,
                    get_variable(optimization_container, val)[ci_name, t],
                    -1.0,
                )
            end
            constraint[ci_name, t] = JuMP.@constraint(
                optimization_container.JuMPmodel,
                expression_lb >= constraint_info.multiplier * constraint_info.timeseries[t]
            )
        end
    end
    return
end

@doc raw"""
Constructs upper bound for given variable using a parameter. The constraint is
    built with a time series data vector and a multiplier

# Constraint

``` variable[name, t] <= constraint_infos[name].multiplier * param[name, t] ```

# LaTeX

`` x^{var}_t \leq r^{val} x^{param}_t, \forall t ``
"""
function device_timeseries_param_ub!(
    optimization_container::OptimizationContainer,
    inputs::TimeSeriesConstraintSpecInternal,
)
    time_steps = model_time_steps(optimization_container)
    names = [get_component_name(x) for x in inputs.constraint_infos]
    variable =
        get_variable(optimization_container, inputs.variable_type, inputs.component_type)
    con_ub = add_cons_container!(
        optimization_container,
        inputs.constraint_type,
        inputs.component_type,
        names,
        time_steps,
        meta = "ub",
    )
    container = add_param_container!(
        optimization_container,
        inputs.param_reference,
        names,
        time_steps,
    )
    multiplier = get_multiplier_array(container)
    param = get_parameter_array(container)
    lazy_add_lb = false

    for constraint_info in inputs.constraint_infos
        ci_name = get_component_name(constraint_info)
        for t in time_steps
            expression_ub = JuMP.AffExpr(0.0, variable[ci_name, t] => 1.0)
            for val in constraint_info.range.additional_terms_ub
                JuMP.add_to_expression!(
                    expression_ub,
                    get_variable(optimization_container, val)[ci_name, t],
                )
            end
            param[ci_name, t] = add_parameter(
                optimization_container.JuMPmodel,
                constraint_info.timeseries[t],
            )
            con_ub[ci_name, t] = JuMP.@constraint(
                optimization_container.JuMPmodel,
                expression_ub <= constraint_info.multiplier * param[ci_name, t]
            )
            multiplier[ci_name, t] = constraint_info.multiplier
        end
        if constraint_info.range.limits.min > -Inf ||
           !isempty(constraint_info.range.additional_terms_lb)
            lazy_add_lb = true
        end
    end

    @debug lazy_add_lb
    lazy_add_lb && lazy_lb!(optimization_container, inputs)
    return
end

@doc raw"""
Constructs lower bound for given variable using a parameter. The constraint is
    built with a time series data vector and a multiplier

# Constraint

``` constraint_infos[name].multiplier * param[name, t] <= variable[name, t] ```

# LaTeX

`` r^{val} x^{param}_t \leq x^{var}_t, \forall t ``
"""
function device_timeseries_param_lb!(
    optimization_container::OptimizationContainer,
    inputs::TimeSeriesConstraintSpecInternal,
)
    time_steps = model_time_steps(optimization_container)
    variable =
        get_variable(optimization_container, inputs.variable_type, inputs.component_type)
    names = [get_component_name(x) for x in inputs.constraint_infos]
    add_cons_container!(
        optimization_container,
        inputs.constraint_type,
        inputs.component_type,
        names,
        time_steps,
        meta = "lb",
    )
    container = add_param_container!(
        optimization_container,
        inputs.param_reference,
        names,
        time_steps,
    )
    multiplier = get_multiplier_array(container)
    param = get_parameter_array(container)

    for constraint_info in inputs.constraint_infos
        ci_name = get_component_name(constraint_info)
        for t in time_steps
            expression_lb = JuMP.AffExpr(0.0, variable[ci_name, t] => 1.0)
            for val in constraint_info.range.additional_terms_lb
                JuMP.add_to_expression!(
                    expression_lb,
                    get_variable(optimization_container, val)[ci_name, t],
                    -1.0,
                )
            end
            param[ci_name, t] = add_parameter(
                optimization_container.JuMPmodel,
                constraint_info.timeseries[t],
            )
            constraint_info[ci_name, t] = JuMP.@constraint(
                optimization_container.JuMPmodel,
                expression_lb >= constraint_info.multiplier * param[ci_name, t]
            )
            multiplier[ci_name, t] = constraint_info.multiplier
        end
    end

    return
end

@doc raw"""
Constructs upper bound for variable and time series or confines to 0 depending on binary variable.
    The upper bound is defined by a time series and a multiplier.

# constraint_infos

``` varcts[name, t] <= varbin[name, t]* constraint_infos[name].multiplier * ts_data[name].timeseries[t] ```

where (name, data) in range_data.

# LaTeX

`` x^{cts}_t \leq r^{val} r_t x^{bin}_t, \forall t ``
"""
function device_timeseries_ub_bin!(
    optimization_container::OptimizationContainer,
    inputs::TimeSeriesConstraintSpecInternal,
)
    time_steps = model_time_steps(optimization_container)
    varcts =
        get_variable(optimization_container, inputs.variable_type, inputs.component_type)
    varbin = get_variable(
        optimization_container,
        inputs.bin_variable_type,
        inputs.component_type,
    )
    names = [get_component_name(x) for x in inputs.constraint_infos]
    con_ub = add_cons_container!(
        optimization_container,
        inputs.constraint_type,
        inputs.component_type,
        names,
        time_steps,
        meta = "ub",
    )
    for constraint_info in inputs.constraint_infos
        ci_name = get_component_name(constraint_info)
        for t in time_steps
            forecast = constraint_info.timeseries[t]
            multiplier = constraint_info.multiplier
            expression_ub = JuMP.AffExpr(0.0, varcts[ci_name, t] => 1.0)
            for val in constraint_info.range.additional_terms_ub
                JuMP.add_to_expression!(
                    expression_ub,
                    get_variable(optimization_container, val)[ci_name, t],
                )
            end
            con_ub[ci_name, t] = JuMP.@constraint(
                optimization_container.JuMPmodel,
                expression_ub <= varbin[ci_name, t] * multiplier * forecast
            )
        end
    end
    return
end

@doc raw"""
Constructs upper bound for variable and time series and a multiplier or confines to 0 depending on binary variable.
    Uses BigM constraint type to allow for parameter since ParameterJuMP doesn't support var*parameter

# constraint_infos

``` varcts[name, t] - constraint_infos[name].multipliers * param[name, t] <= (1 - varbin[name, t]) * M_value ```

``` varcts[name, t] <= varbin[name, t]*M_value ```

# LaTeX

`` x^{cts}_t - r^{val} x^{param}_t \leq M(1 - x^{bin}_t ), forall t ``

`` x^{cts}_t \leq M x^{bin}_t, \forall t ``
"""
function device_timeseries_ub_bigM!(
    optimization_container::OptimizationContainer,
    inputs::TimeSeriesConstraintSpecInternal,
)
    time_steps = model_time_steps(optimization_container)

    varcts =
        get_variable(optimization_container, inputs.variable_type, inputs.component_type)
    varbin = get_variable(
        optimization_container,
        inputs.bin_variable_type,
        inputs.component_type,
    )
    names = [get_component_name(x) for x in inputs.constraint_infos]
    con_ub = add_cons_container!(
        optimization_container,
        inputs.constraint_type,
        inputs.component_type,
        names,
        time_steps,
        meta = "ub",
    )
    con_status = add_cons_container!(
        optimization_container,
        inputs.constraint_type,
        inputs.component_type,
        names,
        time_steps,
        meta = "status",
    )
    container = add_param_container!(
        optimization_container,
        inputs.param_reference,
        names,
        time_steps,
    )
    multiplier = get_multiplier_array(container)
    param = get_parameter_array(container)

    for constraint_info in inputs.constraint_infos
        ci_name = get_component_name(constraint_info)
        for t in time_steps
            expression_ub = JuMP.AffExpr(0.0, varcts[ci_name, t] => 1.0)
            for val in constraint_info.range.additional_terms_ub
                JuMP.add_to_expression!(
                    expression_ub,
                    get_variable(optimization_container, val)[ci_name, t],
                )
            end
            param[ci_name, t] = add_parameter(
                optimization_container.JuMPmodel,
                constraint_info.timeseries[t],
            )
            con_ub[ci_name, t] = JuMP.@constraint(
                optimization_container.JuMPmodel,
                expression_ub - param[ci_name, t] * constraint_info.multiplier <=
                (1 - varbin[ci_name, t]) * M_VALUE
            )
            con_status[ci_name, t] = JuMP.@constraint(
                optimization_container.JuMPmodel,
                expression_ub <= varbin[ci_name, t] * M_VALUE
            )
            multiplier[ci_name, t] = constraint_info.multiplier
        end
    end
    return
end
