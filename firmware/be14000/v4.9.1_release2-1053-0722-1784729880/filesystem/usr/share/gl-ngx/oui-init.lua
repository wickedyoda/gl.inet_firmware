local cjson = require 'cjson'
local db = require 'oui.db'

math.randomseed(ngx.time())

db.init()

local spawn_methods = {}

function spawn_methods:wait()
    return self:read_all()
end

function spawn_methods:read_all()
    if self.data then
        return self.data
    end

    local sock = self.sock
    self.data = sock:receive('*a') or ''
    sock:close()

    return self.data
end

function spawn_methods:stdout_read_all()
    return self:read_all()
end

local spawn_mt = {
    __index = spawn_methods
}

ngx.pipe = {
    spawn = function(...)
        local params = { ... }
        local args = params[1]

        if type(args) == 'string' then
            args = { 'sh', '-c', args }
        end

        local opts = params[2] or {}

        local stdout_read_timeout = opts.stdout_read_timeout or 10000

        local sock = ngx.socket.tcp()
        local ok, err = sock:connect('unix:/var/run/ngx-cmd-proxy.sock')
        if not ok then
            sock:close()
            return nil, err
        end

        local data = cjson.encode({
            args = args,
            timeout = stdout_read_timeout / 1000,
            merge_stderr  = opts.merge_stderr
        })
        local size = #data

        sock:send(size .. '\n')
        sock:send(data)

        sock:settimeout(stdout_read_timeout + 3000)

        return setmetatable({ sock = sock }, spawn_mt)
    end
}
