const BASE_DIR = string(dirname(dirname(pathof(PowerSimulations))))
const DATA_DIR = joinpath(BASE_DIR, "test/test_data")
include(joinpath(DATA_DIR, "data_5bus_pu.jl"))
include(joinpath(DATA_DIR, "data_14bus_pu.jl"))

# Test Systems

# The code below provides a mechanism to optimally construct test systems. The first time a
# test builds a particular system name, the code will construct the system from raw files
# and then serialize it to storage.
# When future tests ask for the same system the code will deserialize it from storage.
#
# If you add a new system then you need to add an entry to TEST_SYSTEMS.
# The build function should accept `kwargs...` instead of specific named keyword arguments.
# This will allow easy addition of new parameters in the future.

struct TestSystemLabel
    name::String
    add_forecasts::Bool
    add_reserves::Bool
end

mutable struct SystemBuildStats
    count::Int
    initial_construct_time::Float64
    serialize_time::Float64
    min_deserialize_time::Float64
    max_deserialize_time::Float64
    total_deserialize_time::Float64
end

function SystemBuildStats(initial_construct_time::Float64, serialize_time::Float64)
    return SystemBuildStats(1, initial_construct_time, serialize_time, 0.0, 0.0, 0.0)
end

function update_stats!(stats::SystemBuildStats, deserialize_time::Float64)
    stats.count += 1
    if stats.min_deserialize_time == 0 || deserialize_time < stats.min_deserialize_time
        stats.min_deserialize_time = deserialize_time
    end
    if deserialize_time > stats.max_deserialize_time
        stats.max_deserialize_time = deserialize_time
    end
    stats.total_deserialize_time += deserialize_time
end

avg_deserialize_time(stats::SystemBuildStats) = stats.total_deserialize_time / stats.count

g_system_serialized_files = Dict{TestSystemLabel, String}()
g_system_build_stats = Dict{TestSystemLabel, SystemBuildStats}()

function initialize_system_serialized_files()
    empty!(g_system_serialized_files)
    empty!(g_system_build_stats)
end

function summarize_system_build_stats()
    @info "System Build Stats"
    labels = sort!(collect(keys(g_system_build_stats)), by = x -> x.name)
    for label in labels
        x = g_system_build_stats[label]
        system = "$(label.name) add_forecasts=$(label.add_forecasts) add_reserves=$(label.add_reserves)"
        @info system x.count x.initial_construct_time x.serialize_time x.min_deserialize_time x.max_deserialize_time avg_deserialize_time(
            x,
        )
    end
end

function build_system(name::String; add_forecasts = true, add_reserves = false)
    !haskey(TEST_SYSTEMS, name) && error("invalid system name: $name")
    label = TestSystemLabel(name, add_forecasts, add_reserves)
    sys_params = TEST_SYSTEMS[name]
    if !haskey(g_system_serialized_files, label)
        @debug "Build new system" label sys_params.description
        build_func = sys_params.build
        start = time()
        sys = build_func(;
            add_forecasts = add_forecasts,
            add_reserves = add_reserves,
            time_series_in_memory = sys_params.time_series_in_memory,
        )
        construct_time = time() - start
        serialized_file = joinpath(mktempdir(), "sys.json")
        start = time()
        PSY.to_json(sys, serialized_file)
        serialize_time = time() - start
        g_system_build_stats[label] = SystemBuildStats(construct_time, serialize_time)
        g_system_serialized_files[label] = serialized_file
    else
        @debug "Deserialize system from file" label
        start = time()
        sys = System(
            g_system_serialized_files[label];
            time_series_in_memory = sys_params.time_series_in_memory,
        )
        update_stats!(g_system_build_stats[label], time() - start)
    end

    return sys
end

function build_c_sys5(; kwargs...)
    nodes = nodes5()
    c_sys5 =
        System(100.0, nodes, thermal_generators5(nodes), loads5(nodes), branches5(nodes))

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5))
                add_forecast!(
                    c_sys5,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
        end
    end

    return c_sys5
end

function build_c_sys5_ml(; kwargs...)
    nodes = nodes5()
    c_sys5_ml = System(
        100.0,
        nodes,
        thermal_generators5(nodes),
        loads5(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_ml))
                add_forecast!(
                    c_sys5_ml,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
        end
    end

    return c_sys5_ml
end

function build_c_sys14(; kwargs...)
    nodes = nodes14()
    c_sys14 = System(
        100.0,
        nodes,
        thermal_generators14(nodes),
        loads14(nodes),
        branches14(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for (ix, l) in enumerate(get_components(PowerLoad, c_sys14))
            add_forecast!(
                c_sys14,
                l,
                Deterministic("get_max_active_power", timeseries_DA14[ix]),
            )
        end
    end

    return c_sys14
end

function build_c_sys5_re(; kwargs...)
    nodes = nodes5()
    c_sys5_re = System(
        100.0,
        nodes,
        thermal_generators5(nodes),
        renewable_generators5(nodes),
        loads5(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_re))
                add_forecast!(
                    c_sys5_re,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
            for (ix, r) in enumerate(get_components(RenewableGen, c_sys5_re))
                add_forecast!(
                    c_sys5_re,
                    r,
                    Deterministic("get_max_active_power", ren_timeseries_DA[t][ix]),
                )
            end
        end
    end

    if get(kwargs, :add_reserves, false)
        reserve_re = reserve5_re(get_components(RenewableDispatch, c_sys5_re))
        add_service!(c_sys5_re, reserve_re[1], get_components(RenewableDispatch, c_sys5_re))
        add_service!(
            c_sys5_re,
            reserve_re[2],
            [collect(get_components(RenewableDispatch, c_sys5_re))[end]],
        )
        add_service!(c_sys5_re, reserve_re[3], get_components(RenewableDispatch, c_sys5_re))
        for t in 1:2, (ix, serv) in enumerate(get_components(VariableReserve, c_sys5_re))
            add_forecast!(c_sys5_re, serv, Deterministic("get_requirement", Reserve_ts[t]))
        end
        for t in 1:2, serv in get_components(ReserveDemandCurve, c_sys5_re)
            add_forecast!(
                c_sys5_re,
                serv,
                PiecewiseFunction("get_variable", 5, ORDC_cost_ts[t]),
            )
        end
    end

    return c_sys5_re
end

function build_c_sys5_re_only(; kwargs...)
    nodes = nodes5()
    c_sys5_re_only = System(
        100.0,
        nodes,
        renewable_generators5(nodes),
        loads5(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_re_only))
                add_forecast!(
                    c_sys5_re_only,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
            for (ix, r) in enumerate(get_components(RenewableGen, c_sys5_re_only))
                add_forecast!(
                    c_sys5_re_only,
                    r,
                    Deterministic("get_max_active_power", ren_timeseries_DA[t][ix]),
                )
            end
        end
    end

    return c_sys5_re_only
end

function build_c_sys5_hy(; kwargs...)
    nodes = nodes5()
    c_sys5_hy = System(
        100.0,
        nodes,
        thermal_generators5(nodes),
        [hydro_generators5(nodes)[1]],
        loads5(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_hy))
                add_forecast!(
                    c_sys5_hy,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
            for (ix, h) in enumerate(get_components(HydroGen, c_sys5_hy))
                add_forecast!(
                    c_sys5_hy,
                    h,
                    Deterministic("get_max_active_power", hydro_timeseries_DA[t][ix]),
                )
            end
        end
    end

    return c_sys5_hy
end

function build_c_sys5_hyd(; kwargs...)
    nodes = nodes5()
    c_sys5_hyd = System(
        100.0,
        nodes,
        thermal_generators5(nodes),
        [hydro_generators5(nodes)[2]],
        loads5(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_hyd))
                add_forecast!(
                    c_sys5_hyd,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
            for (ix, h) in enumerate(get_components(HydroGen, c_sys5_hyd))
                add_forecast!(
                    c_sys5_hyd,
                    h,
                    Deterministic("get_max_active_power", hydro_timeseries_DA[t][ix]),
                )
            end
            for (ix, h) in enumerate(get_components(HydroEnergyReservoir, c_sys5_hyd))
                add_forecast!(
                    c_sys5_hyd,
                    h,
                    Deterministic("get_hydro_budget", hydro_budget_DA[t][ix]),
                )
            end
            for (ix, h) in enumerate(get_components(HydroEnergyReservoir, c_sys5_hyd))
                add_forecast!(
                    c_sys5_hyd,
                    h,
                    Deterministic("get_inflow", hydro_timeseries_DA[t][ix] .* 0.8),
                )
            end
        end
    end

    if get(kwargs, :add_reserves, false)
        reserve_hy = reserve5_hy(get_components(HydroEnergyReservoir, c_sys5_hyd))
        add_service!(
            c_sys5_hyd,
            reserve_hy[1],
            get_components(HydroEnergyReservoir, c_sys5_hyd),
        )
        add_service!(
            c_sys5_hyd,
            reserve_hy[2],
            [collect(get_components(HydroEnergyReservoir, c_sys5_hyd))[end]],
        )
        add_service!(
            c_sys5_hyd,
            reserve_hy[3],
            get_components(HydroEnergyReservoir, c_sys5_hyd),
        )
        for t in 1:2, (ix, serv) in enumerate(get_components(VariableReserve, c_sys5_hyd))
            add_forecast!(c_sys5_hyd, serv, Deterministic("get_requirement", Reserve_ts[t]))
        end
        for t in 1:2, serv in get_components(ReserveDemandCurve, c_sys5_hyd)
            add_forecast!(
                c_sys5_hyd,
                serv,
                PiecewiseFunction("get_variable", 5, ORDC_cost_ts[t]),
            )
        end
    end

    return c_sys5_hyd
end

function build_c_sys5_bat(; kwargs...)
    time_series_in_memory = get(kwargs, :time_series_in_memory, true)
    nodes = nodes5()
    c_sys5_bat = System(
        100.0,
        nodes,
        thermal_generators5(nodes),
        renewable_generators5(nodes),
        loads5(nodes),
        branches5(nodes),
        battery5(nodes);
        time_series_in_memory = time_series_in_memory,
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_bat))
                add_forecast!(
                    c_sys5_bat,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
        end
    end

    if get(kwargs, :add_reserves, false)
        reserve_bat = reserve5_re(get_components(
            RenewableDispatch,
            build_c_sys5_re(; time_series_in_memory = time_series_in_memory),
        ))
        add_service!(c_sys5_bat, reserve_bat[1], get_components(GenericBattery, c_sys5_bat))
        add_service!(c_sys5_bat, reserve_bat[2], get_components(GenericBattery, c_sys5_bat))
        add_service!(c_sys5_bat, reserve_bat[3], get_components(GenericBattery, c_sys5_bat))
        for t in 1:2, (ix, serv) in enumerate(get_components(VariableReserve, c_sys5_bat))
            add_forecast!(c_sys5_bat, serv, Deterministic("get_requirement", Reserve_ts[t]))
        end
        for t in 1:2, serv in get_components(ReserveDemandCurve, c_sys5_bat)
            add_forecast!(
                c_sys5_bat,
                serv,
                PiecewiseFunction("get_variable", 5, ORDC_cost_ts[t]),
            )
        end
    end

    return c_sys5_bat
end

function build_c_sys5_il(; kwargs...)
    nodes = nodes5()
    c_sys5_il = System(
        100.0,
        nodes,
        thermal_generators5(nodes),
        loads5(nodes),
        interruptible(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_il))
                add_forecast!(
                    c_sys5_il,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
            for (ix, i) in enumerate(get_components(InterruptibleLoad, c_sys5_il))
                add_forecast!(
                    c_sys5_il,
                    i,
                    Deterministic("get_max_active_power", Iload_timeseries_DA[t][ix]),
                )
            end
        end
    end

    if get(kwargs, :add_reserves, false)
        reserve_il = reserve5_il(get_components(InterruptibleLoad, c_sys5_il))
        add_service!(c_sys5_il, reserve_il[1], get_components(InterruptibleLoad, c_sys5_il))
        add_service!(
            c_sys5_il,
            reserve_il[2],
            [collect(get_components(InterruptibleLoad, c_sys5_il))[end]],
        )
        add_service!(c_sys5_il, reserve_il[3], get_components(InterruptibleLoad, c_sys5_il))
        for t in 1:2, (ix, serv) in enumerate(get_components(VariableReserve, c_sys5_il))
            add_forecast!(c_sys5_il, serv, Deterministic("get_requirement", Reserve_ts[t]))
        end
        for t in 1:2, serv in get_components(ReserveDemandCurve, c_sys5_il)
            add_forecast!(
                c_sys5_il,
                serv,
                PiecewiseFunction("get_variable", 5, ORDC_cost_ts[t]),
            )
        end
    end

    return c_sys5_il
end

function build_c_sys5_dc(; kwargs...)
    nodes = nodes5()
    c_sys5_dc = System(
        100.0,
        nodes,
        thermal_generators5(nodes),
        renewable_generators5(nodes),
        loads5(nodes),
        branches5_dc(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_dc))
                add_forecast!(
                    c_sys5_dc,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
            for (ix, r) in enumerate(get_components(RenewableGen, c_sys5_dc))
                add_forecast!(
                    c_sys5_dc,
                    r,
                    Deterministic("get_max_active_power", ren_timeseries_DA[t][ix]),
                )
            end
        end
    end

    return c_sys5_dc
end

function build_c_sys14_dc(; kwargs...)
    nodes = nodes14()
    c_sys14_dc = System(
        100.0,
        nodes,
        thermal_generators14(nodes),
        loads14(nodes),
        branches14_dc(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for (ix, l) in enumerate(get_components(PowerLoad, c_sys14_dc))
            add_forecast!(
                c_sys14_dc,
                l,
                Deterministic("get_max_active_power", timeseries_DA14[ix]),
            )
        end
    end

    return c_sys14_dc
end

function build_c_sys5_reg(; kwargs...)
    nodes = nodes5()

    c_sys5_reg =
        System(100.0, nodes, thermal_generators5(nodes), loads5(nodes), branches5(nodes))

    area = Area("1")
    add_component!(c_sys5_reg, area)
    [set_area!(b, area) for b in get_components(Bus, c_sys5_reg)]
    AGC_service = PSY.AGC(
        name = "AGC_Area1",
        available = true,
        bias = 739.0,
        K_p = 2.5,
        K_i = 0.1,
        K_d = 0.0,
        delta_t = 4,
        area = first(get_components(Area, c_sys5_reg)),
    )
    #add_component!(c_sys5_reg, AGC_service)
    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_reg))
                add_forecast!(
                    c_sys5_reg,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
            for (_, l) in enumerate(get_components(ThermalStandard, c_sys5_reg))
                add_forecast!(
                    c_sys5_reg,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][1]),
                )
            end
        end
    end

    contributing_devices = Vector()
    for g in get_components(Generator, c_sys5_reg)
        droop = isa(g, ThermalStandard) ? 0.04 * PSY.get_base_power(g) :
            0.05 * PSY.get_base_power(g)
        p_factor = (up = 1.0, dn = 1.0)
        t = RegulationDevice(g, participation_factor = p_factor, droop = droop)
        add_component!(c_sys5_reg, t)
        push!(contributing_devices, t)
        @assert has_forecasts(t)
    end
    add_service!(c_sys5_reg, AGC_service, contributing_devices)
    return c_sys5_reg
end

# System to test UC Forms
#Park City and Sundance Have non-binding Ramp Limitst at an Hourly Resolution
# Solitude, Sundance and Brighton have binding time_up constraints.
# Solitude and Brighton have binding time_dn constraints.
# Sundance has non-binding Time Down constraint at an Hourly Resolution
# Alta, Park City and Brighton start at 0.

thermal_generators5_uc_testing(nodes) = [
    ThermalStandard(
        name = "Alta",
        available = true,
        status = false,
        bus = nodes[1],
        active_power = 0.0,
        reactive_power = 0.0,
        rating = 0.5,
        prime_mover = PrimeMovers.ST,
        fuel = ThermalFuels.COAL,
        active_power_limits = (min = 0.2, max = 0.40),
        reactive_power_limits = (min = -0.30, max = 0.30),
        ramp_limits = nothing,
        time_limits = nothing,
        operation_cost = ThreePartCost((0.0, 1400.0), 0.0, 4.0, 2.0),
        base_power = 100.0,
    ),
    ThermalStandard(
        name = "Park City",
        available = true,
        status = false,
        bus = nodes[1],
        active_power = 0.0,
        reactive_power = 0.0,
        rating = 2.2125,
        prime_mover = PrimeMovers.ST,
        fuel = ThermalFuels.COAL,
        active_power_limits = (min = 0.65, max = 1.70),
        reactive_power_limits = (min = -1.275, max = 1.275),
        ramp_limits = (up = 0.02 * 2.2125, down = 0.02 * 2.2125),
        time_limits = nothing,
        operation_cost = ThreePartCost((0.0, 1500.0), 0.0, 1.5, 0.75),
        base_power = 100.0,
    ),
    ThermalStandard(
        name = "Solitude",
        available = true,
        status = true,
        bus = nodes[3],
        active_power = 2.7,
        reactive_power = 0.00,
        rating = 5.20,
        prime_mover = PrimeMovers.ST,
        fuel = ThermalFuels.COAL,
        active_power_limits = (min = 1.0, max = 5.20),
        reactive_power_limits = (min = -3.90, max = 3.90),
        ramp_limits = (up = 0.0012 * 5.2, down = 0.0012 * 5.2),
        time_limits = (up = 5.0, down = 3.0),
        operation_cost = ThreePartCost((0.0, 3000.0), 0.0, 3.0, 1.5),
        base_power = 100.0,
    ),
    ThermalStandard(
        name = "Sundance",
        available = true,
        status = false,
        bus = nodes[4],
        active_power = 0.0,
        reactive_power = 0.00,
        rating = 2.5,
        prime_mover = PrimeMovers.ST,
        fuel = ThermalFuels.COAL,
        active_power_limits = (min = 1.0, max = 2.0),
        reactive_power_limits = (min = -1.5, max = 1.5),
        ramp_limits = (up = 0.015 * 2.5, down = 0.015 * 2.5),
        time_limits = (up = 2.0, down = 1.0),
        operation_cost = ThreePartCost((0.0, 4000.0), 0.0, 4.0, 2.0),
        base_power = 100.0,
    ),
    ThermalStandard(
        name = "Brighton",
        available = true,
        status = true,
        bus = nodes[5],
        active_power = 6.0,
        reactive_power = 0.0,
        rating = 7.5,
        prime_mover = PrimeMovers.ST,
        fuel = ThermalFuels.COAL,
        active_power_limits = (min = 3.0, max = 6.0),
        reactive_power_limits = (min = -4.50, max = 4.50),
        ramp_limits = (up = 0.0015 * 7.5, down = 0.0015 * 7.5),
        time_limits = (up = 5.0, down = 3.0),
        operation_cost = ThreePartCost((0.0, 1000.0), 0.0, 1.5, 0.75),
        base_power = 100.0,
    ),
];

function build_sys_ramp_testing(; kwargs...)
    node = Bus(1, "nodeA", "REF", 0, 1.0, (min = 0.9, max = 1.05), 230, nothing, nothing)
    load = PowerLoad("Bus1", true, node, nothing, 0.4, 0.9861, 100.0, 1.0, 2.0)
    DA_ramp = collect(
        DateTime("1/1/2024  0:00:00", "d/m/y  H:M:S"):Hour(1):DateTime(
            "1/1/2024  4:00:00",
            "d/m/y  H:M:S",
        ),
    )
    gen_ramp = [
        ThermalStandard(
            name = "Alta",
            available = true,
            status = true,
            bus = node,
            active_power = 0.20, # Active power
            reactive_power = 0.010,
            rating = 0.5,
            prime_mover = PrimeMovers.ST,
            fuel = ThermalFuels.COAL,
            active_power_limits = (min = 0.0, max = 0.40),
            reactive_power_limits = nothing,
            ramp_limits = nothing,
            time_limits = nothing,
            operation_cost = ThreePartCost((0.0, 1400.0), 0.0, 4.0, 2.0),
            base_power = 100.0,
        ),
        ThermalStandard(
            name = "Park City",
            available = true,
            status = true,
            bus = node,
            active_power = 0.70, # Active Power
            reactive_power = 0.20,
            rating = 2.0,
            prime_mover = PrimeMovers.ST,
            fuel = ThermalFuels.COAL,
            active_power_limits = (min = 0.7, max = 2.20),
            reactive_power_limits = nothing,
            ramp_limits = (up = 0.010625 * 2.0, down = 0.010625 * 2.0),
            time_limits = nothing,
            operation_cost = ThreePartCost((0.0, 1500.0), 0.0, 1.5, 0.75),
            base_power = 100.0,
        ),
    ]
    ramp_load = [0.9, 1.1, 2.485, 2.175, 0.9]
    load_forecast_ramp =
        Deterministic("get_max_active_power", TimeArray(DA_ramp, ramp_load))
    ramp_test_sys = System(100.0)
    add_component!(ramp_test_sys, node)
    add_component!(ramp_test_sys, load)
    add_component!(ramp_test_sys, gen_ramp[1])
    add_component!(ramp_test_sys, gen_ramp[2])
    add_forecast!(ramp_test_sys, load, load_forecast_ramp)
    return ramp_test_sys
end

function build_c_sys5_uc(; kwargs...)
    nodes = nodes5()
    c_sys5_uc = System(
        100.0,
        nodes,
        thermal_generators5_uc_testing(nodes),
        loads5(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_uc))
                add_forecast!(
                    c_sys5_uc,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
            for (ix, r) in enumerate(get_components(RenewableGen, c_sys5_uc))
                add_forecast!(
                    c_sys5_uc,
                    r,
                    Deterministic("get_max_active_power", ren_timeseries_DA[t][ix]),
                )
            end
            for (ix, i) in enumerate(get_components(InterruptibleLoad, c_sys5_uc))
                add_forecast!(
                    c_sys5_uc,
                    i,
                    Deterministic("get_max_active_power", Iload_timeseries_DA[t][ix]),
                )
            end
        end
    end

    if get(kwargs, :add_reserves, false)
        reserve_uc = reserve5(get_components(ThermalStandard, c_sys5_uc))
        add_service!(c_sys5_uc, reserve_uc[1], get_components(ThermalStandard, c_sys5_uc))
        add_service!(
            c_sys5_uc,
            reserve_uc[2],
            [collect(get_components(ThermalStandard, c_sys5_uc))[end]],
        )
        add_service!(c_sys5_uc, reserve_uc[3], get_components(ThermalStandard, c_sys5_uc))
        add_service!(c_sys5_uc, reserve_uc[4], get_components(ThermalStandard, c_sys5_uc))
        for t in 1:2, (ix, serv) in enumerate(get_components(VariableReserve, c_sys5_uc))
            add_forecast!(c_sys5_uc, serv, Deterministic("get_requirement", Reserve_ts[t]))
        end
        for t in 1:2, serv in get_components(ReserveDemandCurve, c_sys5_uc)
            add_forecast!(
                c_sys5_uc,
                serv,
                PiecewiseFunction("get_variable", 5, ORDC_cost_ts[t]),
            )
        end

    end

    return c_sys5_uc
end

function build_c_sys5_pwl_uc(; kwargs...)
    c_sys5_uc = build_c_sys5_uc(; kwargs...)
    thermal = thermal_generators5_pwl(collect(get_components(Bus, c_sys5_uc)))
    for d in thermal
        PSY.add_component!(c_sys5_uc, d)
    end
    return c_sys5_uc
end

function build_c_sys5_ed(; kwargs...)
    nodes = nodes5()
    c_sys5_ed = System(
        100.0,
        nodes,
        thermal_generators5_uc_testing(nodes),
        renewable_generators5(nodes),
        loads5(nodes),
        interruptible(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2 # loop over days
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_ed))
                ta = load_timeseries_DA[t][ix]
                for i in 1:length(ta) # loop over hours
                    ini_time = timestamp(ta[i]) #get the hour
                    data = when(load_timeseries_RT[t][ix], hour, hour(ini_time[1])) # get the subset ts for that hour
                    add_forecast!(c_sys5_ed, l, Deterministic("get_max_active_power", data))
                end
            end
        end
        for t in 1:2
            for (ix, l) in enumerate(get_components(RenewableGen, c_sys5_ed))
                ta = load_timeseries_DA[t][ix]
                for i in 1:length(ta) # loop over hours
                    ini_time = timestamp(ta[i]) #get the hour
                    data = when(load_timeseries_RT[t][ix], hour, hour(ini_time[1])) # get the subset ts for that hour
                    add_forecast!(c_sys5_ed, l, Deterministic("get_max_active_power", data))
                end
            end
        end
        for t in 1:2
            for (ix, l) in enumerate(get_components(InterruptibleLoad, c_sys5_ed))
                ta = load_timeseries_DA[t][ix]
                for i in 1:length(ta) # loop over hours
                    ini_time = timestamp(ta[i]) #get the hour
                    data = when(load_timeseries_RT[t][ix], hour, hour(ini_time[1])) # get the subset ts for that hour
                    add_forecast!(c_sys5_ed, l, Deterministic("get_max_active_power", data))
                end
            end
        end
    end

    return c_sys5_ed
end

function build_c_sys5_pwl_ed(; kwargs...)
    c_sys5_ed = build_c_sys5_ed(; kwargs...)
    thermal = thermal_generators5_pwl(collect(get_components(Bus, c_sys5_ed)))
    for d in thermal
        PSY.add_component!(c_sys5_ed, d)
    end
    return c_sys5_ed
end

function build_c_sys5_pwl_ed_nonconvex(; kwargs...)
    c_sys5_ed = build_c_sys5_ed(; kwargs...)
    thermal = thermal_generators5_pwl_nonconvex(collect(get_components(Bus, c_sys5_ed)))
    for d in thermal
        PSY.add_component!(c_sys5_ed, d)
    end
    return c_sys5_ed
end

function build_init(gens, data)
    init = Vector{InitialCondition}(undef, length(collect(gens)))
    for (ix, g) in enumerate(gens)
        init[ix] = InitialCondition(
            g,
            PSI.UpdateRef{JuMP.VariableRef}(PSI.ACTIVE_POWER),
            data[ix],
            TimeStatusChange,
        )
    end
    return init
end

function build_c_sys5_hy_uc(; kwargs...)
    nodes = nodes5()
    c_sys5_hy_uc = System(
        100.0,
        nodes,
        thermal_generators5_uc_testing(nodes),
        hydro_generators5(nodes),
        renewable_generators5(nodes),
        loads5(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_hy_uc))
                add_forecast!(
                    c_sys5_hy_uc,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
            for (ix, h) in enumerate(get_components(HydroEnergyReservoir, c_sys5_hy_uc))
                add_forecast!(
                    c_sys5_hy_uc,
                    h,
                    Deterministic("get_max_active_power", hydro_timeseries_DA[t][ix]),
                )
            end
            for (ix, h) in enumerate(get_components(HydroEnergyReservoir, c_sys5_hy_uc))
                add_forecast!(
                    c_sys5_hy_uc,
                    h,
                    Deterministic("get_storage_capacity", hydro_timeseries_DA[t][ix]),
                )
            end
            for (ix, h) in enumerate(get_components(HydroEnergyReservoir, c_sys5_hy_uc))
                add_forecast!(
                    c_sys5_hy_uc,
                    h,
                    Deterministic("get_inflow", hydro_timeseries_DA[t][ix] .* 0.8),
                )
            end
            for (ix, h) in enumerate(get_components(HydroDispatch, c_sys5_hy_uc))
                add_forecast!(
                    c_sys5_hy_uc,
                    h,
                    Deterministic("get_max_active_power", hydro_timeseries_DA[t][ix]),
                )
            end
            for (ix, r) in enumerate(get_components(RenewableGen, c_sys5_hy_uc))
                add_forecast!(
                    c_sys5_hy_uc,
                    r,
                    Deterministic("get_max_active_power", ren_timeseries_DA[t][ix]),
                )
            end
            for (ix, i) in enumerate(get_components(InterruptibleLoad, c_sys5_hy_uc))
                add_forecast!(
                    c_sys5_hy_uc,
                    i,
                    Deterministic("get_max_active_power", Iload_timeseries_DA[t][ix]),
                )
            end
        end
    end

    return c_sys5_hy_uc
end

function build_c_sys5_hy_ed(; kwargs...)
    nodes = nodes5()
    c_sys5_hy_ed = System(
        100.0,
        nodes,
        thermal_generators5_uc_testing(nodes),
        hydro_generators5(nodes),
        renewable_generators5(nodes),
        loads5(nodes),
        interruptible(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_hy_ed))
                ta = load_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(load_timeseries_RT[t][ix], hour, hour(ini_time[1]))
                    add_forecast!(
                        c_sys5_hy_ed,
                        l,
                        Deterministic("get_max_active_power", data),
                    )
                end
            end
            for (ix, l) in enumerate(get_components(HydroEnergyReservoir, c_sys5_hy_ed))
                ta = hydro_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(hydro_timeseries_RT[t][ix], hour, hour(ini_time[1]))
                    add_forecast!(
                        c_sys5_hy_ed,
                        l,
                        Deterministic("get_max_active_power", data),
                    )
                end
            end
            for (ix, l) in enumerate(get_components(RenewableGen, c_sys5_hy_ed))
                ta = load_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(load_timeseries_RT[t][ix], hour, hour(ini_time[1]))
                    add_forecast!(
                        c_sys5_hy_ed,
                        l,
                        Deterministic("get_max_active_power", data),
                    )
                end
            end
            for (ix, l) in enumerate(get_components(HydroEnergyReservoir, c_sys5_hy_ed))
                ta = hydro_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(hydro_timeseries_RT[t][ix], hour, hour(ini_time[1]))
                    add_forecast!(
                        c_sys5_hy_ed,
                        l,
                        Deterministic("get_storage_capacity", data),
                    )
                end
            end
            for (ix, l) in enumerate(get_components(HydroEnergyReservoir, c_sys5_hy_ed))
                ta = hydro_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(hydro_timeseries_RT[t][ix] .* 0.8, hour, hour(ini_time[1]))
                    add_forecast!(c_sys5_hy_ed, l, Deterministic("get_inflow", data))
                end
            end
            for (ix, l) in enumerate(get_components(InterruptibleLoad, c_sys5_hy_ed))
                ta = load_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(load_timeseries_RT[t][ix], hour, hour(ini_time[1]))
                    add_forecast!(
                        c_sys5_hy_ed,
                        l,
                        Deterministic("get_max_active_power", data),
                    )
                end
            end
            for (ix, l) in enumerate(get_components(HydroDispatch, c_sys5_hy_ed))
                ta = hydro_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(hydro_timeseries_RT[t][ix], hour, hour(ini_time[1]))
                    add_forecast!(
                        c_sys5_hy_ed,
                        l,
                        Deterministic("get_max_active_power", data),
                    )
                end
            end
        end
    end

    return c_sys5_hy_ed
end

function build_c_sys5_phes_ed(; kwargs...)
    nodes = nodes5()
    c_sys5_phes_ed = System(
        100.0,
        nodes,
        thermal_generators5_uc_testing(nodes),
        phes5(nodes),
        renewable_generators5(nodes),
        loads5(nodes),
        interruptible(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_phes_ed))
                ta = load_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(load_timeseries_RT[t][ix], hour, hour(ini_time[1]))
                    add_forecast!(
                        c_sys5_phes_ed,
                        l,
                        Deterministic("get_max_active_power", data),
                    )
                end
            end
            for (ix, l) in enumerate(get_components(HydroGen, c_sys5_phes_ed))
                ta = hydro_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(hydro_timeseries_RT[t][ix], hour, hour(ini_time[1]))
                    add_forecast!(
                        c_sys5_phes_ed,
                        l,
                        Deterministic("get_max_active_power", data),
                    )
                end
            end
            for (ix, l) in enumerate(get_components(RenewableGen, c_sys5_phes_ed))
                ta = load_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(load_timeseries_RT[t][ix], hour, hour(ini_time[1]))
                    add_forecast!(
                        c_sys5_phes_ed,
                        l,
                        Deterministic("get_max_active_power", data),
                    )
                end
            end
            for (ix, l) in enumerate(get_components(HydroPumpedStorage, c_sys5_phes_ed))
                ta = hydro_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(hydro_timeseries_RT[t][ix], hour, hour(ini_time[1]))
                    add_forecast!(
                        c_sys5_phes_ed,
                        l,
                        Deterministic("get_storage_capacity", data),
                    )
                    add_forecast!(c_sys5_phes_ed, l, Deterministic("get_outflow", data))

                end
            end
            for (ix, l) in enumerate(get_components(
                Union{HydroEnergyReservoir, HydroPumpedStorage},
                c_sys5_phes_ed,
            ))
                ta = hydro_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(hydro_timeseries_RT[t][ix] .* 0.8, hour, hour(ini_time[1]))
                    add_forecast!(c_sys5_phes_ed, l, Deterministic("get_inflow", data))
                end
            end
            for (ix, l) in enumerate(get_components(InterruptibleLoad, c_sys5_phes_ed))
                ta = load_timeseries_DA[t][ix]
                for i in 1:length(ta)
                    ini_time = timestamp(ta[i])
                    data = when(load_timeseries_RT[t][ix], hour, hour(ini_time[1]))
                    add_forecast!(
                        c_sys5_phes_ed,
                        l,
                        Deterministic("get_max_active_power", data),
                    )
                end
            end
        end
    end

    return c_sys5_phes_ed
end

function build_c_sys5_pglib(; kwargs...)
    nodes = nodes5()
    c_sys5_uc = System(
        100.0,
        nodes,
        thermal_generators5_uc_testing(nodes),
        thermal_pglib_generators5(nodes),
        loads5(nodes),
        branches5(nodes);
        time_series_in_memory = get(kwargs, :time_series_in_memory, true),
    )

    if get(kwargs, :add_forecasts, true)
        for t in 1:2
            for (ix, l) in enumerate(get_components(PowerLoad, c_sys5_uc))
                add_forecast!(
                    c_sys5_uc,
                    l,
                    Deterministic("get_max_active_power", load_timeseries_DA[t][ix]),
                )
            end
        end
    end

    if get(kwargs, :add_reserves, false)
        reserve_uc = reserve5(get_components(ThermalStandard, c_sys5_uc))
        add_service!(c_sys5_uc, reserve_uc[1], get_components(ThermalStandard, c_sys5_uc))
        add_service!(
            c_sys5_uc,
            reserve_uc[2],
            [collect(get_components(ThermalStandard, c_sys5_uc))[end]],
        )
        add_service!(c_sys5_uc, reserve_uc[3], get_components(ThermalStandard, c_sys5_uc))
        for t in 1:2, (ix, serv) in enumerate(get_components(VariableReserve, c_sys5_uc))
            add_forecast!(c_sys5_uc, serv, Deterministic("get_requirement", Reserve_ts[t]))
        end
    end

    return c_sys5_uc
end

TEST_SYSTEMS = Dict(
    "c_sys14" => (
        description = "14-bus system",
        build = build_c_sys14,
        time_series_in_memory = true,
    ),
    "c_sys14_dc" =>
        (description = "", build = build_c_sys14_dc, time_series_in_memory = true),
    "c_sys5" => (
        description = "5-bus system",
        build = build_c_sys5,
        time_series_in_memory = true,
    ),
    "c_sys5_bat" => (
        description = "5-bus system with Storage Device",
        build = build_c_sys5_bat,
        time_series_in_memory = true,
    ),
    "c_sys5_dc" => (
        description = "Systems with HVDC data in the branches",
        build = build_c_sys5_dc,
        time_series_in_memory = true,
    ),
    "c_sys5_ed" =>
        (description = "", build = build_c_sys5_ed, time_series_in_memory = true),
    "c_sys5_hy" => (
        description = "5-bus system with HydroPower Energy",
        build = build_c_sys5_hy,
        time_series_in_memory = true,
    ),
    "c_sys5_hy_ed" =>
        (description = "", build = build_c_sys5_hy_ed, time_series_in_memory = true),
    "c_sys5_phes_ed" =>
        (description = "", build = build_c_sys5_phes_ed, time_series_in_memory = true),
    "c_sys5_hy_uc" =>
        (description = "", build = build_c_sys5_hy_uc, time_series_in_memory = true),
    "c_sys5_hyd" =>
        (description = "", build = build_c_sys5_hyd, time_series_in_memory = true),
    "c_sys5_il" => (
        description = "System with Interruptible Load",
        build = build_c_sys5_il,
        time_series_in_memory = true,
    ),
    "c_sys5_ml" =>
        (description = "", build = build_c_sys5_ml, time_series_in_memory = true),
    "c_sys5_re" => (
        description = "5-bus system with Renewable Energy",
        build = build_c_sys5_re,
        time_series_in_memory = true,
    ),
    "c_sys5_re_only" =>
        (description = "", build = build_c_sys5_re_only, time_series_in_memory = true),
    "c_sys5_uc" =>
        (description = "", build = build_c_sys5_uc, time_series_in_memory = true),
    "c_sys5_pglib" => (
        description = "5-bus with ThermalMultiStart",
        build = build_c_sys5_pglib,
        time_series_in_memory = true,
    ),
    "c_sys5_pwl_uc" => (
        description = "5-bus with SOS cost function",
        build = build_c_sys5_pwl_uc,
        time_series_in_memory = true,
    ),
    "c_sys5_pwl_ed" => (
        description = "5-bus with pwl cost function",
        build = build_c_sys5_pwl_ed,
        time_series_in_memory = true,
    ),
    "c_sys5_pwl_ed_nonconvex" => (
        description = "5-bus with SOS cost function",
        build = build_c_sys5_pwl_ed_nonconvex,
        time_series_in_memory = true,
    ),
    "c_sys5_reg" => (
        description = "5-bus with regulation devices and AGC",
        build = build_c_sys5_reg,
        time_series_in_memory = true,
    ),
    "c_ramp_test" => (
        description = "1-bus for ramp testing",
        build = build_sys_ramp_testing,
        time_series_in_memory = true,
    ),
)

build_PTDF5() = PTDF(build_system("c_sys5"))
build_PTDF14() = PTDF(build_system("c_sys14"))
build_PTDF5_dc() = PTDF(build_system("c_sys5_dc"))
build_PTDF14_dc() = PTDF(build_system("c_sys14_dc"))
