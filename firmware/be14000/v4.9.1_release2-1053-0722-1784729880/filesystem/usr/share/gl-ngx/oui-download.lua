local fs = require "oui.fs"
local ubus = require "oui.ubus"
local rpc = require "oui.rpc"

local function path_is_allowed(dir, to)
    if to:match("%.%.") or to:match("~") then
        return false
    end

    for conf in fs.dir(dir) do
        if conf ~= "." and conf ~= ".." then
            for line in io.lines(dir .. conf) do
                if #line > 0 and to:match('^' .. line) then
                    return true
                end
            end
        end
    end

    return false
end

local function path_is_allowed_download(to)
    return path_is_allowed("/usr/share/gl-download.d/", to)
end

if ngx.req.get_method() ~= "POST" then
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

local headers = ngx.req.get_headers()
if not headers["Content-Type"] then
    ngx.log(ngx.ERR, "not found header: Content-Type")
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

if not headers["Content-Type"]:match("application/x%-www%-form%-urlencoded") then
    ngx.log(ngx.ERR, "Content-Type must be application/x-www-form-urlencoded")
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

ngx.req.read_body()

local data = ngx.req.get_body_data()
if not data then
    local name = ngx.req.get_body_file()
    local f = io.open(name, "r")
    data = f:read("*a")
    f:close()
end

local authed = false

local params = ngx.decode_args(data, 0)

local path = params["path"]
if not path then
    ngx.log(ngx.ERR, "not found param: path")
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

if not path_is_allowed_download(path) then
    ngx.log(ngx.ERR, "Not allowed path")
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

local sid = params["sid"]
if sid then
    local session = ubus.call("gl-session", "session", { sid = sid })
    if session then
        ngx.ctx.sid = sid
        authed = true
    end
end

local is_local = ngx.var.remote_addr == "127.0.0.1" or ngx.var.remote_addr == "::1"

if not authed and not is_local then
    ngx.exit(ngx.HTTP_UNAUTHORIZED)
end

if not fs.access(path) then
    ngx.exit(ngx.HTTP_NOT_FOUND)
end

if authed then
    if not rpc.access("download", path) then
        ngx.exit(ngx.HTTP_FORBIDDEN)
    end
end

local f, err = io.open(path, "r")
if not f then
    ngx.log(ngx.ERR, err)
    ngx.exit(ngx.HTTP_NOT_FOUND)
end

local st = fs.stat(path)

if not st then return ngx.exit(ngx.HTTP_NOT_FOUND) end

local size = st.size
local filename = params["filename"]
ngx.header["Content-Length"] = size
if filename then ngx.header["Content-Disposition"] = "attachment; filename=" .. filename end
ngx.header["Content-Type"] = "application/octet-stream"

data = f:read(40960)
while data do
    ngx.print(data)
    data = f:read(40960)
end

f:close()

if path_is_allowed_download(path) and params["delete"] then
    os.remove(path)
end
