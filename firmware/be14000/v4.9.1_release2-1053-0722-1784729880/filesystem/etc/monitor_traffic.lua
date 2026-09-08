#!/usr/bin/env eco
--luacheck: ignore 311

local socket = require 'eco.socket'
local sys = require 'eco.sys'
local json = require 'cjson'
local sqlite3 = require 'lsqlite3'
local time = require "eco.time"
local log = require 'eco.log'

local DB_PATH = "/tmp/traffic_data.db"

local db = nil
local update_timer
local protocol_map_cache = nil

local function get_client_data_by_socket(cmd)
    local sock, _ = socket.connect_unix('/tmp/gl_clients.sock')
    if not sock then
        return nil
    end
    local ok, result = pcall(function()
        sock:send(cmd.."\n")
        local data_len = sock:recv('l')
        if data_len == nil then return nil end
        local data = sock:recvfull(tonumber(data_len))
        if data == nil then return nil end
        return json.decode(data)
    end)
    sock:close()
    return ok and result or nil
end

local function get_protocol_mapping()
    protocol_map_cache = {}
    local handle = io.popen("netifyd --dump-protos")
    if not handle then return end
    local output = handle:read("*a")
    handle:close()

    for line in output:gmatch("[^\r\n]+") do
        local id, name = line:match("^%s*(%d+):%s*(.+)$")
        if id and name then
            protocol_map_cache[tonumber(id)] = name == "Unknown" and "other" or name
        end
    end
    return
end

sys.signal(sys.SIGINT, function()
    if db then db:close() end
    eco.unloop()
end)

local function init_database()
    local err
    db, err = sqlite3.open(DB_PATH)
    if not db then
        log.err("Failed to open database: " .. err)
    end

    db:exec("PRAGMA journal_mode = WAL;")
    db:exec("PRAGMA wal_autocheckpoint = 100;")

    local limit_mb = 20
    local limit_bytes = limit_mb * 1024 * 1024
    db:exec(string.format("PRAGMA journal_size_limit = %d;", limit_bytes))
    db:exec("PRAGMA synchronous=NORMAL;")

    local sql = [[
        CREATE TABLE IF NOT EXISTS raw_traffic_data (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            log_time_start INTEGER NOT NULL,
            log_time_end INTEGER NOT NULL,
            application_id TEXT NOT NULL,
            application_name TEXT,
            download_bytes INTEGER DEFAULT 0,
            upload_bytes INTEGER DEFAULT 0,
            packets INTEGER DEFAULT 0,
            local_ip TEXT,
            local_mac TEXT,
            protocol_id INTEGER,
            timestamp INTEGER NOT NULL,
            category_name TEXT,
            category_id TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_main ON raw_traffic_data(application_id, application_name, timestamp, local_mac);
        CREATE INDEX IF NOT EXISTS idx_raw_traffic_timestamp ON raw_traffic_data(timestamp, local_mac);
        CREATE INDEX IF NOT EXISTS idx_raw_traffic_time_range ON raw_traffic_data(log_time_end);
    ]]

    local result = db:exec(sql)
    if result ~= sqlite3.OK then
        log.err("Failed to create tables: " .. db:errmsg())
    end

end

local function safe_get_number(value, default)
    default = default or 0
    if value == nil then return default end
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) or default end
    return default
end

local function extract_app_info(application_id)
    local app_id = application_id
    local app_name = application_id

    if application_id and string.find(application_id, "netify.") then
        local numeric_id = string.match(application_id, "^(%d+)%.")
        if numeric_id then
            app_id = numeric_id
        end

        app_name = string.match(application_id, "netify%.(.*)")
    end

    return app_id, app_name
end

local function cleanup_old_data()
    if not db then return 0 end

    local cutoff_time = os.time() - (8 * 24 * 3600)

    db:exec("BEGIN TRANSACTION;")

    local stmt = db:prepare("DELETE FROM raw_traffic_data WHERE timestamp < ?")
    stmt:bind(1, cutoff_time)

    stmt:step()
    local deleted_count = db:changes()

    stmt:finalize()

    db:exec("COMMIT;")

    return deleted_count
end

local function save_raw_data(log_time_start, log_time_end, app_stat)
    if not db then return false end

    local app_id, app_name = extract_app_info(app_stat.application_id or "unknown")
    local protocol_id = safe_get_number(app_stat.protocol_id)
    local current_time = os.time()

    local file = io.open("/etc/netifyd/netify-categories.json", "r")
    if not file then
        return nil, "not find netify-categories.json"
    end

    local json_content = file:read("*a")
    file:close()

    if not json_content then
        return nil, "Failed to read file: " .. "unknown error"
    end

    local category_name
    local category_id

    local data = json.decode(json_content)
    if data then
        local category_tag_index = data.application_tag_index or {}
        local application_index = data.application_index or {}

        for _, item in ipairs(application_index) do
            local cat_id = tostring(item[1])
            local app_ids = item[2] or {}

            for _, app_id_in_index in ipairs(app_ids) do
                if tostring(app_id_in_index) == tostring(app_id) then
                    for tag, id_in_index in pairs(category_tag_index) do
                        if tostring(id_in_index) == cat_id then
                            category_name = tag:gsub("^netify%.", "")
                            category_id = cat_id
                            break
                        end
                    end
                    break
                end
            end
        end
    end

    local protocol_name = protocol_map_cache[protocol_id] or "other"

    local stmt = db:prepare([[
        INSERT INTO raw_traffic_data
        (log_time_start, log_time_end, application_id, application_name,
         download_bytes, upload_bytes, packets, local_ip, local_mac, protocol_id, timestamp, category_name, category_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])

    stmt:bind(1, log_time_start)
    stmt:bind(2, log_time_end)
    stmt:bind(3, app_id)
    if tonumber(app_id) == 0 then
        stmt:bind(4, protocol_name)
    else
        stmt:bind(4, app_name)
    end
    stmt:bind(5, safe_get_number(app_stat.download))
    stmt:bind(6, safe_get_number(app_stat.upload))
    stmt:bind(7, safe_get_number(app_stat.packets))
    stmt:bind(8, app_stat.local_ip or "")
    stmt:bind(9, app_stat.local_mac or "")
    stmt:bind(10, protocol_id)
    stmt:bind(11, current_time)
    stmt:bind(12, category_name)
    stmt:bind(13, category_id)

    local result = stmt:step()
    stmt:finalize()

    return result == sqlite3.DONE
end

local function process_traffic_data(json_data)
    local ok, data = pcall(json.decode, json_data)
    if not ok then
        return
    end

    if not data or not data.stats or type(data.stats) ~= "table" or #data.stats == 0 then
        return
    end

    local log_time_start = safe_get_number(data.log_time_start)
    local log_time_end = safe_get_number(data.log_time_end)
    local saved_count = 0
    local r = get_client_data_by_socket("list") or {}

    local mac_lookup = {}
    for mac, _ in pairs(r.clients or {}) do
        mac_lookup[string.upper(mac)] = true
    end
    db:exec("BEGIN TRANSACTION;")

    for _, app_stat in ipairs(data.stats) do
        if app_stat and app_stat.application_id and app_stat.local_mac then
            if mac_lookup[string.upper(app_stat.local_mac)] then
                if save_raw_data(log_time_start, log_time_end, app_stat) then
                    saved_count = saved_count + 1
                end
            end
        end
    end

    db:exec("COMMIT;")

    return saved_count
end

local function aggregate_daily_traffic()
    if not db then return end

    local now = os.time()
    local hour_ago = now - 3600
    local day_ago = now - 24 * 3600

    db:exec("PRAGMA wal_checkpoint(PASSIVE);")

    db:exec("BEGIN TRANSACTION;")

    local five_min_stmt = db:prepare([[
        SELECT
            application_id,
            application_name,
            category_name,
            category_id,
            local_mac,
            protocol_id,
            (((log_time_end + 299) / 300) * 300) as five_min_interval,
            SUM(download_bytes) as total_download,
            SUM(upload_bytes) as total_upload,
            SUM(packets) as total_packets
        FROM raw_traffic_data
        WHERE log_time_end >= ? AND log_time_end <= ?
        GROUP BY
            CASE
                WHEN application_id = 0 THEN protocol_id
                ELSE application_id
            END,
            local_mac,
            (((log_time_end + 299) / 300) * 300)
    ]])
    five_min_stmt:bind(1, day_ago)
    five_min_stmt:bind(2, hour_ago)

    local aggregated_data = {}
    while five_min_stmt:step() == sqlite3.ROW do
        local interval_end = five_min_stmt:get_value(6)
        local interval_start = interval_end - 300
        aggregated_data[#aggregated_data + 1] = {
            application_id = five_min_stmt:get_value(0),
            application_name = five_min_stmt:get_value(1),
            category_name = five_min_stmt:get_value(2),
            category_id = five_min_stmt:get_value(3),
            local_mac = five_min_stmt:get_value(4),
            protocol_id = five_min_stmt:get_value(5),
            interval_timestamp = interval_end,
            download_bytes = five_min_stmt:get_value(7),
            upload_bytes = five_min_stmt:get_value(8),
            packets = five_min_stmt:get_value(9),
            log_time_start = interval_start,
            log_time_end = interval_end
        }
    end
    five_min_stmt:finalize()

    local daily_stmt = db:prepare([[
        SELECT
            application_id,
            application_name,
            category_name,
            category_id,
            local_mac,
            protocol_id,
            strftime('%Y-%m-%d', log_time_end, 'unixepoch') as log_date,
            SUM(download_bytes) as total_download,
            SUM(upload_bytes) as total_upload,
            SUM(packets) as total_packets
        FROM raw_traffic_data
        WHERE log_time_end < ?
        GROUP BY
            CASE
                WHEN application_id = 0 THEN protocol_id
                ELSE application_id
            END,
            local_mac,
            strftime('%Y-%m-%d', log_time_end, 'unixepoch')
    ]])
    daily_stmt:bind(1, day_ago)

    while daily_stmt:step() == sqlite3.ROW do
        local year, month, day = string.match(daily_stmt:get_value(6), "(%d+)-(%d+)-(%d+)")
        local date_timestamp = os.time({year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 0, min = 0, sec = 0})
        aggregated_data[#aggregated_data + 1] = {
            application_id = daily_stmt:get_value(0),
            application_name = daily_stmt:get_value(1),
            category_name = daily_stmt:get_value(2),
            category_id = daily_stmt:get_value(3),
            local_mac = daily_stmt:get_value(4),
            protocol_id = daily_stmt:get_value(5),
            download_bytes = daily_stmt:get_value(7),
            upload_bytes = daily_stmt:get_value(8),
            packets = daily_stmt:get_value(9),
            log_time_start = date_timestamp,
            log_time_end = date_timestamp + 86399,
            interval_timestamp = date_timestamp + 86399
        }
    end
    daily_stmt:finalize()

    local delete_stmt = db:prepare([[
        DELETE FROM raw_traffic_data
        WHERE (log_time_end >= ? AND log_time_end <= ?)
           OR log_time_end < ?
    ]])

    delete_stmt:bind(1, day_ago)
    delete_stmt:bind(2, hour_ago)
    delete_stmt:bind(3, day_ago)

    delete_stmt:step()
    delete_stmt:finalize()

    for _, data in ipairs(aggregated_data) do
        local insert_stmt = db:prepare([[
            INSERT INTO raw_traffic_data
            (log_time_start, log_time_end, application_id, application_name,
             download_bytes, upload_bytes, packets, local_ip, local_mac, protocol_id, timestamp, category_name, category_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])

        insert_stmt:bind(1, data.log_time_start)
        insert_stmt:bind(2, data.log_time_end)
        insert_stmt:bind(3, data.application_id)
        insert_stmt:bind(4, data.application_name)
        insert_stmt:bind(5, data.download_bytes)
        insert_stmt:bind(6, data.upload_bytes)
        insert_stmt:bind(7, data.packets)
        insert_stmt:bind(8, "")
        insert_stmt:bind(9, data.local_mac)
        if data.application_id == "0" then
            insert_stmt:bind(10, data.protocol_id)
        else
            insert_stmt:bind(10, 0)
        end
        insert_stmt:bind(11, data.interval_timestamp)
        insert_stmt:bind(12, data.category_name)
        insert_stmt:bind(13, data.category_id)

        insert_stmt:step()
        insert_stmt:finalize()
    end

    db:exec("COMMIT;")
    db:exec("PRAGMA wal_checkpoint(FULL);")
    db:exec("VACUUM;")
    cleanup_old_data()
    sys.sh('sqlite3 /tmp/traffic_data.db ".backup /etc/netifyd/traffic_data.db"')
    update_timer:set(60*60)
end

local function main()
    init_database()
    update_timer = time.timer(function()
        aggregate_daily_traffic()
    end)
    update_timer:set(1)

    while true do
        local s, err = socket.connect_tcp('127.0.0.1', 1780)
        if not s then
            log.err("Connect error: " .. err)
            log.info("Will try to reconnect in 5 seconds...")
            eco.sleep(5)
        else
            get_protocol_mapping()
            local buffer = ""
            while true do
                local data, err = s:recv(65536)
                if data then
                    buffer = buffer .. data
                    if data:sub(-3) == "}]}" then
                        process_traffic_data(buffer)
                        buffer = ""
                    end
                elseif err == "timeout" or err == "again" then
                    buffer = ""
                    eco.sleep(0.1)
                elseif err == "closed" then
                    buffer = ""
                    log.info("Connection closed by server")
                    s:close()
                    break
                else
                    buffer = ""
                    log.err("Receive error: " .. err)
                    s:close()
                    break
                end
            end
        end
    end

    -- if db then
    --     db:close()
    -- end
end

main()
