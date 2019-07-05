local t = require('luatest')
local g = t.group('failover')

local test_helper = require('test.helper')

local helpers = require('cluster.test_helpers')

local cluster = helpers.Cluster:new({
    datadir = test_helper.datadir,
    use_vshard = true,
    server_command = test_helper.server_command,
    replicasets = {
        {
            alias = 'router',
            uuid = helpers.uuid('a'),
            roles = {'vshard-router'},
            servers = {
                {instance_uuid = helpers.uuid('a', 'a', 1)},
            },
        },
        {
            alias = 'storage',
            uuid = helpers.uuid('b'),
            roles = {'vshard-router', 'vshard-storage'},
            servers = {
                {instance_uuid = helpers.uuid('b', 'b', 1)},
                {instance_uuid = helpers.uuid('b', 'b', 2)},
            },
        },
    },
})

local replicaset_uuid = cluster.replicasets[2].uuid
local storage_1_uuid = cluster:server('storage-1').instance_uuid
local storage_2_uuid = cluster:server('storage-2').instance_uuid

local function get_master(uuid)
    local response = cluster.main_server:graphql({
        query = [[
            query(
                $uuid: String!
            ){
                replicasets(uuid: $uuid) {
                    master { uuid }
                    active_master { uuid }
                }
            }
        ]],
        variables = {uuid = uuid}
    })
    local replicasets = response.data.replicasets
    t.assert_equals(#replicasets, 1)
    local replicaset = replicasets[1]
    return {replicaset.master.uuid, replicaset.active_master.uuid}
end

local function set_master(uuid, master_uuid)
    cluster.main_server:graphql({
        query = [[
            mutation(
                $uuid: String!
                $master_uuid: [String!]!
            ) {
                edit_replicaset(
                    uuid: $uuid
                    master: $master_uuid
                )
            }
        ]],
        variables = {uuid = uuid, master_uuid = {master_uuid}}
    })
end

local function get_failover()
    return cluster.main_server:graphql({query = [[
        {
            cluster { failover }
        }
    ]]}).data.cluster.failover
end

local function set_failover(enabled)
    local response = cluster.main_server:graphql({
        query = [[
            mutation($enabled: Boolean!) {
                cluster { failover(enabled: $enabled) }
            }
        ]],
        variables = {enabled = enabled}
    })
    return response.data.cluster.failover
end

local function check_active_master(expected_uuid)
    -- Make sure active master uuid equals to the given uuid
    local response = cluster.main_server.net_box:eval([[
        return require('vshard').router.callrw(1, 'get_uuid')
    ]])
    t.assert_equals(response, expected_uuid)
end

g.before_all = function() cluster:start() end
g.after_all = function() cluster:stop() end

g.test_api_master = function()
    set_master(replicaset_uuid, storage_2_uuid)
    t.assert_equals(get_master(replicaset_uuid), {storage_2_uuid, storage_2_uuid})
    set_master(replicaset_uuid, storage_1_uuid)
    t.assert_equals(get_master(replicaset_uuid), {storage_1_uuid, storage_1_uuid})

    local invalid_uuid = helpers.uuid('b', 'b', 3)
    t.assert_error_msg_contains(
        'replicasets[' .. replicaset_uuid .. '].master "' .. invalid_uuid .. '" doesn\'t exist',
        function() set_master(replicaset_uuid, invalid_uuid) end
    )

    t.assert_error_msg_contains(
        'Server "' .. storage_1_uuid .. '" is the master and can\'t be expelled',
        function()
            cluster.main_server:graphql({
                query = 'mutation($uuid: String!) { expel_server(uuid: $uuid) }',
                variables = {uuid = storage_1_uuid},
            })
        end
    )

    local response = cluster.main_server:graphql({query = [[
        {
            replicasets {
                uuid
                servers { uuid priority }
            }
        }
    ]]})
    t.assert_items_equals(response.data.replicasets, {
        {
            uuid = helpers.uuid('a'),
            servers = {{uuid = helpers.uuid('a', 'a', 1), priority = 1}},
        },
        {
            uuid = replicaset_uuid,
            servers = {
                {uuid = storage_1_uuid, priority = 1},
                {uuid = storage_2_uuid, priority = 2},
            }
        },
    })
end

g.test_api_failover = function()
    t.assert_equals(false, set_failover(false))
    t.assert_equals(false, get_failover())
    t.assert_equals(true, set_failover(true))
    t.assert_equals(true, get_failover())
end

g.test_switchover = function()
    set_failover(false)

    -- Switch to server1
    set_master(replicaset_uuid, storage_1_uuid)
    cluster:retrying({}, check_active_master, storage_1_uuid)
    t.assert_equals(get_master(replicaset_uuid), {storage_1_uuid, storage_1_uuid})

    -- Switch to server2
    set_master(replicaset_uuid, storage_2_uuid)
    cluster:retrying({}, check_active_master, storage_2_uuid)
    t.assert_equals(get_master(replicaset_uuid), {storage_2_uuid, storage_2_uuid})
end

g.test_sigkill = function()
    set_failover(true)

    -- Switch to server1
    set_master(replicaset_uuid, storage_1_uuid)
    cluster:retrying({}, check_active_master, storage_1_uuid)
    t.assert_equals(get_master(replicaset_uuid), {storage_1_uuid, storage_1_uuid})

    local server = cluster:server('storage-1')
    -- Send SIGKILL to server1
    server:stop()
    cluster:retrying({}, check_active_master, storage_2_uuid)
    t.assert_equals(get_master(replicaset_uuid), {storage_1_uuid, storage_2_uuid})

    -- Restart server1
    server:start()
    cluster:retrying({}, function() server:connect_net_box() end)
    cluster:retrying({}, check_active_master, storage_1_uuid)
    t.assert_equals(get_master(replicaset_uuid), {storage_1_uuid, storage_1_uuid})
end

g.test_sigstop = function()
    set_failover(true)

    -- Switch to server1
    set_master(replicaset_uuid, storage_1_uuid)
    cluster:retrying({}, check_active_master, storage_1_uuid)
    t.assert_equals(get_master(replicaset_uuid), {storage_1_uuid, storage_1_uuid})

    -- Send SIGSTOP to server1
    cluster:server('storage-1').process:kill('STOP')
    cluster:retrying({timeout = 60, delay = 2}, check_active_master, storage_2_uuid)
    t.assert_equals(get_master(replicaset_uuid), {storage_1_uuid, storage_2_uuid})

    local response = cluster.main_server:graphql({query = [[
        {
            servers {
                uri
                statistics { }
            }
        }
    ]]})

    t.assert_items_equals(response.data.servers, {
        {uri = cluster:server('storage-1').advertise_uri, statistics = box.NULL},
        {uri = cluster:server('storage-2').advertise_uri, statistics = {}},
        {uri = cluster:server('router-1').advertise_uri, statistics={}}
    })

    -- Send SIGCONT to server1
    cluster:server('storage-1').process:kill('CONT') -- SIGCONT
    cluster:wait_until_healthy()
    cluster:retrying({}, check_active_master, storage_1_uuid)
    t.assert_equals(get_master(replicaset_uuid), {storage_1_uuid, storage_1_uuid})

    response = cluster.main_server:graphql({query = [[
        {
            servers {
                uri
                statistics { }
            }
        }
    ]]})

    t.assert_items_equals(response.data.servers, {
        {uri = cluster:server('storage-1').advertise_uri, statistics = {}},
        {uri = cluster:server('storage-2').advertise_uri, statistics = {}},
        {uri = cluster:server('router-1').advertise_uri, statistics={}}
    })
end

g.test_rollback = function()
    local server = cluster:server('storage-1')

    -- hack utils to throw error on file_write
    server.net_box:eval([[
        local utils = package.loaded["cluster.utils"]
        local e_file_write = require('errors').new_class("Artificial error")
        _G._utils_file_write = utils.file_write
        utils.file_write = function(filename)
            return nil, e_file_write:new("Hacked from test")
        end
    ]])

    -- try to apply new config - it should fail
    t.assert_error_msg_contains('Hacked from test', function()
        cluster.main_server:graphql({query = [[
            mutation {
                cluster { failover(enabled: false) }
            }
        ]]})
    end)

    -- restore utils.file_write
    server.net_box:eval([[
        local utils = package.loaded["cluster.utils"]
        utils.file_write = _G._utils_file_write
        _G._utils_file_write = nil
    ]])

    -- try to apply new config - now it should succeed
    cluster.main_server:graphql({query = [[
        mutation {
            cluster { failover(enabled: false) }
        }
    ]]})
end
