local t = require('luatest')
local g = t.group()

local fio = require('fio')

local helpers = require('test.helper')

g.before_all(function()
    g.cluster = helpers.Cluster:new({
        datadir = fio.tempdir(),
        use_vshard = false,
        server_command = helpers.entrypoint('srv_basic'),
        cookie = require('digest').urandom(6):hex(),
        replicasets = {
            {
                alias = 'initial-alias',
                uuid = helpers.uuid('a'),
                roles = {},
                servers = {
                    {instance_uuid = helpers.uuid('a', 'a', 1)},
                },
            },
        },
    })
    g.cluster:start()
end)

g.after_all(function()
    g.cluster:stop()
    fio.rmtree(g.cluster.datadir)
    g.cluster = nil
end)

g.test_rename_replicaset = function()
    local server = g.cluster.main_server

    local function query()
        return server:graphql({
            query = ([[{
                replicasets(uuid: %q) { uuid, alias } }
            ]]):format(server.replicaset_uuid)
        }).data.replicasets[1]
    end

    t.assert_equals(query(), {
        uuid = server.replicaset_uuid,
        alias = 'initial-alias',
    })

    local alias = 'another-alias'
    server:graphql({
        query = [[
            mutation(
                $uuid: String!
                $alias: String!
            ){
                edit_replicaset(
                    uuid: $uuid
                    alias: $alias
                )
            }
        ]],
        variables = {
            uuid = server.replicaset_uuid,
            alias = alias
        }
    })

    t.assert_equals(query(), {
        uuid = server.replicaset_uuid,
        alias = 'another-alias',
    })
end
