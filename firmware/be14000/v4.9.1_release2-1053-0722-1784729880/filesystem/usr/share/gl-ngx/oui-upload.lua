local upload = require "resty.upload"
local fs = require "oui.fs"
local ubus = require "oui.ubus"
local rpc = require "oui.rpc"
local lfactory = require 'lfactory'

local form, err = upload:new(40960)
if not form then
    ngx.log(ngx.ERR, "failed to new upload: ", err)
    ngx.exit(500)
end

form:set_timeout(15000)

local name
local contents = {}
local authed = false
local upload_perm_checked = false
local path
local size
local f

local function get_tmp_size()
    local f = io.popen("df | grep tmpfs | awk -F' ' '{print$4}' | head -n 1 | sed 's/[a-zA-Z]/ /g'")
    if f then
        local size = f:read("*a")
        f:close()
        if size then
            return tonumber(size)/1024
        end
    end
    return nil
end

local function check_size()
    if not size or not path then
        return
    end

    local c = size / (1024 * 1024)
    if path:find('ovpn') then
        for file in fs.dir("/tmp/ovpn_upload") do
            if file ~= "." and file ~= ".." then
                os.remove("/tmp/ovpn_upload/" .. file)
            end
        end

        for file in fs.dir("/tmp/ovpn_confirm") do
            if file ~= "." and file ~= ".." then
                os.remove("/tmp/ovpn_confirm/" .. file)
            end
        end
        c = 2 * c --at least two times the size os uploaded file
        local tmp_size = get_tmp_size()
        if tmp_size then
            tmp_size = tmp_size
            if c >= tmp_size then
                ngx.log(ngx.ERR, "the uploaded file is too large, please decrease the file size.")
                ngx.exit(413)
            end
        end
    end

    if path:find('firmware') then
        if fs.access("/tmp/firmware.img") then
            os.remove("/tmp/firmware.img")
        end

        if fs.access("/tmp/upgrade_cellular/firmware.zip") then
            os.remove("/tmp/upgrade_cellular/firmware.zip")
        end

        local model = lfactory.get_model()
        if model == "b3000" or model == "x2000" then
            os.remove("/tmp/ubi.bin")
            c = 2 * c
        elseif model == "sft3000" then
            c = c + 16
        elseif model == "sft1200" then
            c = c + 12
        end

        local tmp_size = get_tmp_size()
        if tmp_size then
            tmp_size = tmp_size
            if c >= tmp_size then
                ngx.exit(507)
            end
        end
    end

    if path:find("wg_upload") or path:find("ovpn") then
        local lower_path = path:lower()
        if lower_path:match("%.ovpn$") or lower_path:match("%.conf$") or lower_path:match("%.txt$") then
            if size > 256 * 1024 then
                os.remove(path)
                ngx.log(ngx.ERR, string.format("Configuration file is too large (%d bytes), maximum size is 256KB", size))
                ngx.exit(413)
            end
        end
    end
end

local function path_is_allowed(to)
    if to:match("%.%.") or to:match("~") then
        return false
    end

    for conf in fs.dir("/usr/share/gl-upload.d") do
        if conf ~= "." and conf ~= ".." then
            for line in io.lines("/usr/share/gl-upload.d/" .. conf) do
                if #line > 0 and to:match('^' .. line) then
                    return true
                end
            end
        end
    end

    return false
end

while true do
    local typ, res, err = form:read()
    if not typ then
        ngx.log(ngx.ERR, "failed to read: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if typ == "header" and #res > 1 and (res[1] == "Content-Disposition" or res[1] == "content-disposition") then
        name = res[2]:match('name="(%w+)"')
        if not name then
            ngx.log(ngx.ERR, "invalid header: ", table.concat(res, ";"))
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
        contents[name] = {}
    elseif typ == "body" then
        if name == "file" then
            local is_local = ngx.var.remote_addr == "127.0.0.1" or ngx.var.remote_addr == "::1"
            if not authed and not is_local then
                ngx.exit(ngx.HTTP_UNAUTHORIZED)
            end

            if not path then
                ngx.log(ngx.ERR, "Not found path")
                ngx.exit(ngx.HTTP_FORBIDDEN)
            end

            if authed and not upload_perm_checked then
                if not rpc.access("upload", path) then
                    ngx.exit(ngx.HTTP_FORBIDDEN)
                end
                upload_perm_checked = true
            end

            if not size then
                ngx.log(ngx.ERR, "Not found size")
                ngx.exit(ngx.HTTP_FORBIDDEN)
            end

            if not f then
                f, err = io.open(path, "w+")
                if not f then
                    ngx.log(ngx.ERR, "open ", path, " fail: ", err)
                    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
                end
            end

            local _, a = fs.statvfs(fs.dirname(path))
            if a < 1024 * 1024 then
                f:close()
                os.remove(path)
                ngx.log(ngx.ERR, "No enough space left on device")
                ngx.exit(507)
            end

            f:write(res)
        else
            local content = contents[name]
            content[#content + 1] = res
        end
    elseif typ == "part_end" then
        contents[name] = table.concat(contents[name])
        if name == "sid" then
            local sid = contents[name]
            local session = ubus.call("gl-session", "session", { sid = sid })
            if session then
                ngx.ctx.sid = sid
                authed = true
            end
        elseif name == "path" then
            path = contents[name]
            if not path_is_allowed(path) then
                ngx.log(ngx.ERR, "Not allowed path")
                ngx.exit(ngx.HTTP_FORBIDDEN)
            end

            check_size()
        elseif name == "file" then
            if f then
                f:close()
                break
            end
        elseif name == "size" then
            size = tonumber(contents[name])
            if not size then
                ngx.log(ngx.ERR, "Invalid size")
                ngx.exit(ngx.HTTP_FORBIDDEN)
            end

            check_size()
        end
    end

    if typ == "eof" then break end
end

if not f then ngx.exit(ngx.HTTP_FORBIDDEN) end
