--- Administration functions (failover related).
--
-- @module cartridge.lua-api.failover

local checks = require('checks')
local errors = require('errors')

local twophase = require('cartridge.twophase')
local topology = require('cartridge.topology')
local confapplier = require('cartridge.confapplier')
local failover = require('cartridge.failover')
local rpc = require('cartridge.rpc')

local FailoverSetParamsError = errors.new_class('FailoverSetParamsError')
local PromoteLeaderError = errors.new_class('PromoteLeaderError')

--- Get failover configuration.
--
-- (**Added** in v2.0.2-2)
-- @function get_params
-- @treturn FailoverParams
local function get_params()
    --- Failover parameters.
    --
    -- (**Added** in v2.0.2-2)
    -- @table FailoverParams
    -- @tfield string mode
    --   Supported modes are "disabled", "eventual" and "stateful"
    -- @tfield ?string state_provider
    --   Supported state providers are "tarantool" and "etcd2".
    -- @tfield number failover_timeout
    --   (added in v2.3.0-52)
    --   Timeout (in seconds), used by membership to
    --   mark `suspect` members as `dead` (default: 20)
    -- @tfield ?table tarantool_params
    --   (added in v2.0.2-2)
    -- @tfield string tarantool_params.uri
    -- @tfield string tarantool_params.password
    -- @tfield ?table etcd2_params
    --   (added in v2.1.2-26)
    -- @tfield string etcd2_params.prefix
    --   Prefix used for etcd keys: `<prefix>/lock` and
    --   `<prefix>/leaders`
    -- @tfield ?number etcd2_params.lock_delay
    --   Timeout (in seconds), determines lock's time-to-live (default: 10)
    -- @tfield ?table etcd2_params.endpoints
    --   URIs that are used to discover and to access etcd cluster instances.
    --   (default: `{'http://localhost:2379', 'http://localhost:4001'}`)
    -- @tfield ?string etcd2_params.username (default: "")
    -- @tfield ?string etcd2_params.password (default: "")
    -- @tfield boolean fencing_enabled
    --   (added in v2.3.0-57)
    --   Abandon leadership when both the state provider quorum and at
    --   least one replica are lost (suitable in stateful mode only,
    --   default: false)
    -- @tfield number fencing_timeout
    --   (added in v2.3.0-57)
    --   Time (in seconds) to actuate fencing after the check fails
    --   (default: 10)
    -- @tfield number fencing_pause
    --   (added in v2.3.0-57)
    --   The period (in seconds) of performing the check
    --   (default: 2)
    return topology.get_failover_params(
        confapplier.get_readonly('topology')
    )
end

--- Configure automatic failover.
--
-- (**Added** in v2.0.2-2)
-- @function set_params
-- @tparam table opts
-- @tparam ?string opts.mode
-- @tparam ?string opts.state_provider
-- @tparam ?number opts.failover_timeout
--   (added in v2.3.0-52)
-- @tparam ?table opts.tarantool_params
-- @tparam ?table opts.etcd2_params
--   (added in v2.1.2-26)
-- @tparam ?boolean opts.fencing_enabled
--   (added in v2.3.0-57)
-- @tparam ?number opts.fencing_timeout
--   (added in v2.3.0-57)
-- @tparam ?number opts.fencing_pause
--   (added in v2.3.0-57)
-- @treturn[1] boolean `true` if config applied successfully
-- @treturn[2] nil
-- @treturn[2] table Error description
local function set_params(opts)
    checks({
        mode = '?string',
        state_provider = '?string',
        failover_timeout = '?number',
        tarantool_params = '?table',
        etcd2_params = '?table',
        fencing_enabled = '?boolean',
        fencing_timeout = '?number',
        fencing_pause = '?number',
    })

    local topology_cfg = confapplier.get_deepcopy('topology')
    if topology_cfg == nil then
        return nil, FailoverSetParamsError:new(
            "Current instance isn't bootstrapped yet"
        )
    end

    if opts == nil then
        return true
    end

    -- backward compatibility with older clusterwide config
    if topology_cfg.failover == nil then
        topology_cfg.failover = {mode = 'disabled'}
    elseif type(topology_cfg.failover) == 'boolean' then
        topology_cfg.failover = {
            mode = topology_cfg.failover and 'eventual' or 'disabled',
        }
    end

    if opts.mode ~= nil then
        topology_cfg.failover.mode = opts.mode
    end

    if opts.state_provider ~= nil then
        topology_cfg.failover.state_provider = opts.state_provider
    end
    if opts.failover_timeout ~= nil then
        topology_cfg.failover.failover_timeout = opts.failover_timeout
    end
    if opts.tarantool_params ~= nil then
        topology_cfg.failover.tarantool_params = opts.tarantool_params
    end
    if opts.etcd2_params ~= nil then
        topology_cfg.failover.etcd2_params = opts.etcd2_params
    end

    if opts.fencing_enabled ~= nil then
        topology_cfg.failover.fencing_enabled = opts.fencing_enabled
    end
    if opts.fencing_timeout ~= nil then
        topology_cfg.failover.fencing_timeout = opts.fencing_timeout
    end
    if opts.fencing_pause ~= nil then
        topology_cfg.failover.fencing_pause = opts.fencing_pause
    end

    local ok, err = twophase.patch_clusterwide({topology = topology_cfg})
    if not ok then
        return nil, err
    end

    return true
end

--- Get current failover state.
--
-- (**Deprecated** since v2.0.2-2)
-- @function get_failover_enabled
local function get_failover_enabled()
    return get_params().mode ~= 'disabled'
end

--- Enable or disable automatic failover.
--
-- (**Deprecated** since v2.0.2-2)
-- @function set_failover_enabled
-- @tparam boolean enabled
-- @treturn[1] boolean New failover state
-- @treturn[2] nil
-- @treturn[2] table Error description
local function set_failover_enabled(enabled)
    checks('boolean')
    local ok, err = set_params({
        mode = enabled and 'eventual' or 'disabled'
    })
    if ok == nil then
        return nil, err
    end

    return get_failover_enabled()
end

--- Promote leaders in replicasets.
--
-- @function promote
-- @tparam table { [replicaset_uuid] = leader_uuid }
-- @tparam[opt] table opts
-- @tparam ?boolean opts.force_inconsistency
--   (default: **false**)
-- @tparam ?boolean opts.skip_error_on_change
--   Skip etcd error if vclockkeeper was changed between calls (default: **false**)
--
-- @treturn[1] boolean true On success
-- @treturn[2] nil
-- @treturn[2] table Error description
local function promote(replicaset_leaders, opts)
    checks('table', {
        force_inconsistency = '?boolean',
        skip_error_on_change = '?boolean',
    })

    local mode = get_params().mode
    if mode ~= 'stateful' then
        return nil, PromoteLeaderError:new(
            'Promotion only works with stateful failover,' ..
            ' not in %q mode', mode
        )
    end

    local coordinator, err = failover.get_coordinator()
    if err ~= nil then
        return nil, err
    end

    if coordinator == nil then
        return nil, PromoteLeaderError:new('There is no active coordinator')
    end

    local ok, err = rpc.call(
            'failover-coordinator',
            'appoint_leaders',
            {replicaset_leaders},
            { uri = coordinator.uri }
    )

    if ok == nil then
        return nil, err
    end

    if opts ~= nil and opts.force_inconsistency == true then
        local ok, err = failover.force_inconsistency(replicaset_leaders, opts.skip_error_on_change)
        if ok == nil then
            return nil, PromoteLeaderError:new(
                "Promotion succeeded, but inconsistency wasn't forced: %s",
                errors.is_error_object(err) and err.err or err
            )
        end
    end

    local ok, err = failover.wait_consistency(replicaset_leaders)
    if ok == nil then
        return nil, err
    end

    return true
end

return {
    get_params = get_params,
    set_params = set_params,
    promote = promote,
    get_failover_enabled = get_failover_enabled, -- deprecated
    set_failover_enabled = set_failover_enabled, -- deprecated
}
