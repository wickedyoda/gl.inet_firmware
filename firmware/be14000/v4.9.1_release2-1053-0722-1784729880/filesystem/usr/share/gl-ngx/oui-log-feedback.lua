local upload = require "resty.upload"
local fs = require "oui.fs"
local ubus = require "oui.ubus"
local rpc = require "oui.rpc"
local http = require "resty.http"
local cjson = require "cjson"
local utils = require "oui.utils"
local lfactory = require "lfactory"
local uci = require "uci"

local LOG_CODE_SUCCESS = 0
local LOG_ERR_FILE_RECV_FAILED = 20009004
local LOG_ERR_SEND_TO_SERVER_FAILED = 20009005
local LOG_ERR_IMAGE_TOO_BIG = 20009006
local LOG_ERR_NO_ENOUGH_SPACE = 20009007
local LOG_ERR_EMAIL_PARAM_INVALIED = 20009008
local LOG_ERR_NETWORK_CONNECTION_FAILED = 20009009
local LOG_ERR_MAIL_SERVER_ERROR = 20009010
local LOG_ERR_SYSTEM_ERROR = 20009011
local LOG_ERR_SEND_TOO_MANY_TIMES = 20009012
local LOG_ERR_SEND_FREQUENTLY = 20009013
local LOG_ERR_XSS_ATTACK = 20009014

local function result_response(result_obj)
    return {
        result = result_obj or cjson.null
    }
end

local form, err = upload:new(4096)
if not form then
    ngx.log(ngx.ERR, "failed to new upload: ", err)
    ngx.exit(500)
end

form:set_timeout(1000)

local name
local contents = {}
local authed = false
local upload_perm_checked = false
local path
local size
local subject
local dpi_flag = false
local dpi_app_name = ""
local dpi_func_page = ""
local email
local description
local withSysLog
local withDbgInfo
local files = {}
local file_idx = 0
local MAX_IMAGES_SIZE = 10485760 --10M

local function get_tmp_size()
    local f = io.popen("df -h | grep tmpfs | awk -F' ' '{print$4}' | head -n 1 | sed 's/[a-zA-Z]/ /g'")
    if f then
        local size = f:read("*a")
        f:close()
        if size then
            return tonumber(size)
        end
    end
    return nil
end

local total_size = 0
local ret_code = LOG_CODE_SUCCESS
local function check_size()
    if not size or not path then
        ngx.log(ngx.ERR, "the path or size is nil")
        return false
    end
    local c = size / (1024 * 1024)
    if path:find('log_feedback/img') and total_size > MAX_IMAGES_SIZE then
        ngx.log(ngx.ERR, "the uploaded images is too large, please upload images within 10MB.")
        return LOG_ERR_IMAGE_TOO_BIG
    end

    if path:find('log_feedback') then
        local tmp_size = get_tmp_size()
        if tmp_size then
            tmp_size = tmp_size
            if c >= tmp_size then
                ngx.log(ngx.ERR, "there is not enough space left.")
                return LOG_ERR_NO_ENOUGH_SPACE
            end
        end
        local system_info = ubus.call("system", "info", {})
        if system_info then
            local current_size = tonumber(system_info.memory.available)
            if current_size then
                current_size = current_size / (1024 * 1024)
                if c >= current_size then
                    os.execute("echo 3 > /proc/sys/vm/drop_caches")
                    local system_info_clean = ubus.call("system", "info")
                    local current_size_clean = tonumber(system_info_clean.memory.available) or ""
                    if c >= current_size_clean then
                        ngx.log(ngx.ERR, "there is not enough space left.")
                        return LOG_ERR_NO_ENOUGH_SPACE
                    end
                end
            end
        end
    end
    return LOG_CODE_SUCCESS
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

-- Prepare upload directory
ngx.pipe.spawn({"rm", "/tmp/log_feedback", "-rf"}):wait()
ngx.pipe.spawn({"mkdir", "/tmp/log_feedback"}):wait()
ngx.pipe.spawn({"mkdir", "/tmp/log_feedback/img"}):wait()

local recieved_size = 0
-- process multipart/form-data upload
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
            if not files[file_idx] then
                files[file_idx], err = io.open(path, "w+")
                if not files[file_idx] then
                    ngx.log(ngx.ERR, "open ", path, " fail: ", err)
                    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
                end
            end

            local _, a = fs.statvfs(fs.dirname(path))
            if a < 1024 * 1024 then
                files[file_idx]:close()
                os.remove(path)
                ngx.log(ngx.ERR, "No enough space left on device")
                ngx.exit(413)
            end
            recieved_size = recieved_size + #res
            if recieved_size <= MAX_IMAGES_SIZE then
                files[file_idx]:write(res)
            else
                ret_code = LOG_ERR_IMAGE_TOO_BIG
            end
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

            ret_code = check_size()
        elseif name == "file" then
            if files[file_idx] then
                files[file_idx]:close()
                file_idx = file_idx + 1
            end
        elseif name == "size" then
            size = tonumber(contents[name])
            if not size then
                ngx.log(ngx.ERR, "Invalid size")
                ngx.exit(ngx.HTTP_FORBIDDEN)
            end
            total_size = total_size + size
            ret_code = check_size()
        elseif name == "subject" then
            subject = contents[name]
        elseif name == "email" then
            local pattern = "^[A-Za-z0-9._%%+-]+@[A-Za-z0-9.-]+%.[A-Za-z]+$"
            email = contents[name]
            if not email:match(pattern) then
                ngx.status = 200
                local resp = result_response({err_code = LOG_ERR_EMAIL_PARAM_INVALIED, err_msg = 'mailbox format error'})
                ngx.say(cjson.encode(resp))
                ngx.exit(ngx.OK)
            end
        elseif name == "description" then
            description = contents[name]
            local model = utils.readfile('/proc/gl-hw-info/model', '*l')
            local current_version = utils.readfile("/etc/glversion", "*l") or ""
            description = table.concat({
                description,
                "\r\n\r\nModel: ", model,
                "\r\nVersion: ", current_version,
                "\r\n"
            })
        elseif name == "withSysLog" then
            withSysLog = contents[name]
        elseif name == "withDbgInfo" then
            withDbgInfo = contents[name]
        elseif name == "useDpiLog" then
            dpi_flag = contents[name]
        elseif name == "dpiappname" then
            dpi_app_name = contents[name]
        elseif name == "dpifuncpage" then
            dpi_func_page = contents[name]
        end
    end
    if typ == "eof" then break end
end

local is_local = ngx.var.remote_addr == "127.0.0.1" or ngx.var.remote_addr == "::1"
if not authed and not is_local then
    ngx.exit(ngx.HTTP_UNAUTHORIZED)
end

if LOG_CODE_SUCCESS ~= ret_code then
    ret_code = true
    ngx.status = 200
    local resp
    if ret_code == LOG_ERR_IMAGE_TOO_BIG then
        resp = result_response({err_code = LOG_ERR_IMAGE_TOO_BIG, err_msg = 'images is too big'})
    elseif ret_code == LOG_ERR_NO_ENOUGH_SPACE then
        resp = result_response({err_code = LOG_ERR_NO_ENOUGH_SPACE, err_msg = 'there is not enough space left'})
    end
    ngx.say(cjson.encode(resp))
    ngx.exit(ngx.OK)
end

for _, f in ipairs(files) do
    if not f then ngx.exit(ngx.HTTP_FORBIDDEN) end
end

-- check mail send times start(No more than 20 mails per day)
local MAX_MAILS_PER_DAY = 20
local MIN_INTERVAL_SECONDS = 30
local RECORD_FILE = "/tmp/call_record"
local SECONDS_IN_DAY = 24 * 60 * 60

local function read_record()
    local file = io.open(RECORD_FILE, "r")
    if not file then
        return { date = os.time(), count = 0, last_send_time = 0 }
    end

    local date, count, last_send_time = file:read("*l"), file:read("*l"), file:read("*l")
    file:close()

    local now_time = os.time()
    if date + SECONDS_IN_DAY < now_time then
        return { date = now_time, count = 0, last_send_time = now_time }
    end

    return { date = date, count = tonumber(count) or 0, last_send_time = last_send_time or 0 }
end

local function save_record(record)
    local file = io.open(RECORD_FILE, "w")
    if file then
        file:write(record.date .. "\n" .. record.count .. "\n" .. record.last_send_time .. "\n")
        file:close()
    end
end

local function limited_function()
    local record = read_record()
    local now_time = os.time()

    if record.count >= MAX_MAILS_PER_DAY then
        ngx.log(ngx.ERR, "We've reached our limit. Please try again tomorrow!")
        return false
    end
    -- The interval between the two times is too short and the count value not reset,can not send
    if now_time - record.last_send_time < MIN_INTERVAL_SECONDS and record.count ~= 0 then
        return false, record.last_send_time + MIN_INTERVAL_SECONDS - now_time
    end

    record.count = record.count + 1
    record.last_send_time = now_time
    save_record(record)

    return true
end

local limited_ret, wait_time = limited_function()
if not limited_ret then
    local resp
    if not wait_time then
        local msg = "Send too many times, a maximum of 20 emails may be sent per day."
        resp = result_response({err_code = LOG_ERR_SEND_TOO_MANY_TIMES, err_msg = msg})
    else
        local msg = "Send frequently, please try again in "..wait_time.." seconds"
        resp = result_response({err_code = LOG_ERR_SEND_FREQUENTLY, err_msg = msg, wait_time = wait_time})
    end
    ngx.status = 200
    ngx.say(cjson.encode(resp))
    ngx.exit(ngx.OK)
end
-- check mail send times end

-- check network start
local function is_network_available()
    local servers = {
        { host = "223.5.5.5", port = 53 },      -- Alibaba
        { host = "119.29.29.29", port = 53 },   -- Tencent
        { host = "8.8.8.8", port = 53 },        -- Google
        { host = "1.1.1.1", port = 53 },        -- Cloudflare
        { host = "223.5.5.5", port = 80 },
        { host = "119.29.29.29", port = 80 },
        { host = "8.8.8.8", port = 80 },
        { host = "1.1.1.1", port = 80 },
    }
    for _, server in ipairs(servers) do
        local tcp = ngx.socket.tcp()
        tcp:settimeout(800)
        local success = tcp:connect(server.host, server.port)
        tcp:close()
        if success then
            return true
        end
    end
    return false
end

if not is_network_available() then
    ngx.status = 200
    local resp = result_response({err_code = LOG_ERR_NETWORK_CONNECTION_FAILED, err_msg = 'network connection issues'})
    ngx.say(cjson.encode(resp))
    ngx.exit(ngx.OK)
end
-- check network end

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then
        ngx.log(ngx.ERR, "Failed to open file: " .. (err or "unknown error"))
        return nil
    end
    local content = file:read("*all")
    file:close()
    return content
end

local function generate_boundary()
    local boundary = "----WebKitFormBoundary"
    for _ = 1, 16 do
        boundary = boundary .. string.char(math.random(65, 90)) -- A-Z
    end
    return boundary
end

local function upload_logs_and_images(api_url, hostname, params, directory, debug_log_path, system_log_path)
    local httpc = http.new()
    local boundary = generate_boundary()
    local CRLF = "\r\n"
    local body = {}

    -- Add text fields
    for key, value in pairs(params) do
        table.insert(body, "--" .. boundary .. CRLF)
        table.insert(body, 'Content-Disposition: form-data; name="' .. key .. '"' .. CRLF .. CRLF)
        table.insert(body, value .. CRLF)
    end

    -- mac
    local mac = utils.readfile('/proc/gl-hw-info/device_mac', '*l')
    mac = mac:gsub(':', '')
    if not mac or mac == '' then
        ngx.log(ngx.ERR, "mac is invalid")
        return {
            err_code = LOG_ERR_SYSTEM_ERROR,
            err_msg = 'system error'
        }
    end
    table.insert(body, "--" .. boundary .. CRLF)
    table.insert(body, 'Content-Disposition: form-data; name="mac"' .. CRLF .. CRLF)
    table.insert(body, mac .. CRLF)

    -- sn
    local sn = utils.readfile('/proc/gl-hw-info/device_sn', '*l')
    if not sn or sn == '' then
        ngx.log(ngx.ERR, "sn is invalid")
        return {
            err_code = LOG_ERR_SYSTEM_ERROR,
            err_msg = 'system error'
        }
    end
    table.insert(body, "--" .. boundary .. CRLF)
    table.insert(body, 'Content-Disposition: form-data; name="sn"' .. CRLF .. CRLF)
    table.insert(body, sn .. CRLF)

    -- ddns
    local ddns = utils.readfile('/proc/gl-hw-info/device_ddns', '*l')
    if not ddns or ddns == '' then
        ngx.log(ngx.ERR, "ddns is invalid")
        return {
            err_code = LOG_ERR_SYSTEM_ERROR,
            err_msg = 'system error'
        }
    end
    table.insert(body, "--" .. boundary .. CRLF)
    table.insert(body, 'Content-Disposition: form-data; name="ddns"' .. CRLF .. CRLF)
    table.insert(body, ddns .. CRLF)

    -- timestamp
    local timestamp = os.time() .. '000'
    table.insert(body, "--" .. boundary .. CRLF)
    table.insert(body, 'Content-Disposition: form-data; name="timestamp"' .. CRLF .. CRLF)
    table.insert(body, timestamp .. CRLF)

    --password
    local password = utils.readfile('/proc/gl-hw-info/device_sn_bak', '*l')
    if not password or password == '' then
        ngx.log(ngx.ERR, "password is invalid")
        return {
            err_code = LOG_ERR_SYSTEM_ERROR,
            err_msg = 'system error'
        }
    end
    local fl = io.popen(string.format('echo -n "%s" | sha256sum | awk \'{print $1}\'', password))
    password = fl:read("*a")
    fl:close()
    password = password:gsub("%s+", "")

    -- sign
    local cmd
    if dpi_flag == "true" then
        cmd = string.format(
            'echo -n "%s%s%s%s_dpi" | openssl dgst -sha256 -hmac "%s" -hex | awk \'{print $2}\'',
            mac, ddns, timestamp, password, sn
        )
    else
        cmd = string.format(
            'echo -n "%s%s%s%s" | openssl dgst -sha256 -hmac "%s" -hex | awk \'{print $2}\'',
            mac, ddns, timestamp, password, sn
        )
    end

    local f = io.popen(cmd)
    local sign = f:read("*a")
    f:close()

    sign = sign:gsub("%s+", "")
    table.insert(body, "--" .. boundary .. CRLF)
    table.insert(body, 'Content-Disposition: form-data; name="sign"' .. CRLF .. CRLF)
    table.insert(body, sign .. CRLF)

    -- type
    table.insert(body, "--" .. boundary .. CRLF)
    table.insert(body, 'Content-Disposition: form-data; name="type"' .. CRLF .. CRLF)
    table.insert(body, "router" .. CRLF)

    -- Add systemLogFile
    if withSysLog == 'true' then
        local f = assert(io.popen("logread"))
        local system_log_content
        if f then
            system_log_content = f:read("*a")
            f:close()
        end
        if not system_log_content then
            return {
                err_code = LOG_ERR_FILE_RECV_FAILED,
                err_msg = 'file acceptance failed'
            }
        end
        table.insert(body, "--" .. boundary .. CRLF)
        table.insert(body, 'Content-Disposition: form-data; name="systemLogFile"; filename="' .. system_log_path:match("^.+/(.+)$") .. '"' .. CRLF)
        table.insert(body, "Content-Type: application/octet-stream" .. CRLF .. CRLF)
        table.insert(body, system_log_content .. CRLF)
    end

    -- Add debugLogFile
    if withDbgInfo == 'true' then
        ngx.pipe.spawn({"sh", "-c", "cd /tmp/log_feedback; /usr/bin/export_logs only_debug_log"}):wait()
        local debug_log_content = read_file(debug_log_path)
        if not debug_log_content then
            return {
                err_code = LOG_ERR_FILE_RECV_FAILED,
                err_msg = 'file acceptance failed'
            }
        end
        table.insert(body, "--" .. boundary .. CRLF)
        table.insert(body, 'Content-Disposition: form-data; name="debugLogFile"; filename="' .. debug_log_path:match("^.+/(.+)$") .. '"' .. CRLF)
        table.insert(body, "Content-Type: application/octet-stream" .. CRLF .. CRLF)
        table.insert(body, debug_log_content .. CRLF)
    end

    -- Add image files from the directory
    for filename in fs.dir("/tmp/log_feedback/img") do
        if filename ~= "." and filename ~= ".." then
            local file_content = read_file("/tmp/log_feedback/img/" .. filename)
            if not file_content then
                ngx.log(ngx.ERR, "file content is nil")
                return {
                    err_code = LOG_ERR_FILE_RECV_FAILED,
                    err_msg = 'file acceptance failed'
                }
            end
            table.insert(body, "--" .. boundary .. CRLF)
            table.insert(body, 'Content-Disposition: form-data; name="imageFiles"; filename="' .. filename .. '"' .. CRLF)
            table.insert(body, "Content-Type: application/octet-stream" .. CRLF .. CRLF)
            table.insert(body, file_content .. CRLF)
        end
    end

    -- Add ending boundary
    table.insert(body, "--" .. boundary .. "--" .. CRLF)

    -- Concatenate all parts
    local body_data = table.concat(body)

    -- Set request headers
    local headers = {
        ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
        ["Content-Length"] = #body_data,
    }

    -- Send HTTP request
    local res, err = httpc:request_uri(api_url, {
        method = "POST",
        body = body_data,
        headers = headers,
        ssl_verify = true,
        ssl_server_name = hostname
    })

    if not res then
        ngx.log(ngx.ERR, "Request failed: ", err)
        return {
            err_code = LOG_ERR_SEND_TO_SERVER_FAILED,
            err_msg = 'failed to send to server'
        }
    end

    local call_ok, cloud_resp = pcall(cjson.decode, res.body)
    if not call_ok then
        ngx.log(ngx.ERR, "Failed to decode JSON response: ", res.body)
        return {
            err_code = LOG_ERR_SYSTEM_ERROR,
            err_msg = 'system error'
        }
    end

    if cloud_resp.code == 0 then
        return {
            err_code = LOG_CODE_SUCCESS,
            err_msg = 'success'
        }
    elseif cloud_resp.code == -1015 then
        ngx.log(ngx.ERR, "err_msg:", cloud_resp.msg, " status: ", res.status)
        return {
            err_code = LOG_ERR_SEND_TOO_MANY_TIMES,
            err_msg = 'send too many times'
        }
    elseif cloud_resp.code == -1022 then
        ngx.log(ngx.ERR, "err_msg:", cloud_resp.msg, " status: ", res.status)
        return {
            err_code = LOG_ERR_XSS_ATTACK,
            err_msg = 'The  description contains HTML tags (such as < tag >), please modify it and try again.'
        }
    elseif cloud_resp.code == 10000038 then
        ngx.log(ngx.ERR, "err_msg:", cloud_resp.msg, " status: ", res.status)
        return {
            err_code = LOG_ERR_MAIL_SERVER_ERROR,
            err_msg = 'mail server error'
        }
    else
        ngx.log(ngx.ERR, "res.body:", res.body, " status: ", res.status)
        return {
            err_code = LOG_ERR_SYSTEM_ERROR,
            err_msg = 'system error'
        }
    end
end

-- send to GoodCloud server
local country_code = lfactory.get_country_code() or ""
local api_url
local hostname
if country_code == "CN" then
    api_url = "https://api.gl-inet.cn/cloud-api/cloud/v2/log/transferLog"
    hostname = "api.gl-inet.cn"
else
    api_url = "https://api.goodcloud.xyz/cloud-api/cloud/v2/log/transferLog"
    hostname = "api.goodcloud.xyz"
end

if dpi_flag == "true" then
    local version = "first-beta"
    local ret = ubus.call("gl-dpi", "version")
    if ret and ret.version then
        version = ret.version
    end
    if country_code == "CN" then
        api_url = "https://api.gl-inet.cn/cloud-api/cloud/v2/log/transferLog/deviceDpiLogsFeedback"
        hostname = "api.gl-inet.cn"
    else
        api_url = "https://api.goodcloud.xyz/cloud-api/cloud/v2/log/transferLog/deviceDpiLogsFeedback"
        hostname = "api.goodcloud.xyz"
    end
    subject = "DPI " .. subject
    local c = uci.cursor()
    description = table.concat({
                description,
                "DPI_Version: ", version,
                "\r\nLIB_UPDATE_TIME: ", os.date("%Y-%m-%d %H:%M:%S", c:get("gl_dpi", "dpi_config", "lib_update_time")),
                "\r\nAPP_NAME: ",dpi_app_name,
                "\r\nDPI_FUNC_PAGE: ",dpi_func_page,
                "\r\n"
            })
end


local params = {
    subject = subject,
    description = description,
    email = email,
}
local directory = "/tmp/log_feedback/img"
local debug_log_path = "/tmp/log_feedback/debug_info.log"
local system_log_path = "/tmp/log_feedback/system.log"

local res = upload_logs_and_images(api_url,hostname, params, directory, debug_log_path, system_log_path)
if type(res) ~= "table" then res = {} end
local resp = result_response(res)
ngx.say(cjson.encode(resp))
dpi_flag = "false"
