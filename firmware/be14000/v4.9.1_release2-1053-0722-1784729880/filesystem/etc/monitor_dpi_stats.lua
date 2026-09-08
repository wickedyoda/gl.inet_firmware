#!/usr/bin/env eco

local log = require 'eco.log'
local uci = require "uci"
local file = require 'eco.file'

local config = {
    qos_stats_file = "/tmp/qos_stats",
    qos_backup_file = "/etc/netifyd/qos_stats",
    content_protection_stats_file = "/tmp/content_protection_stats",
    content_protection_backup_file = "/etc/netifyd/content_protection_stats",
    interval = 15,
    backup_interval = 3600,
    backup_files_to_keep = 24
}

local function execute_command(cmd)
    local handle = io.popen(cmd .. " 2>/dev/null")
    if not handle then return nil end
    local result = handle:read("*a")
    handle:close()
    return result
end

local function get_parental_drop_count()
    if file.access("/sbin/fw4") then
        local cmd = "nft list counter inet filter block 2>/dev/null"
        local data = execute_command(cmd)
        if not data then return 0 end

        for line in data:gmatch("[^\r\n]+") do
            if line:find("packets") then
                local packets = line:match("packets%s+(%d+)")
                return tonumber(packets) or 0
            end
        end
        return 0
    end
    local data = execute_command("iptables -L parental_control -nvx")
    if not data then return 0 end

    local total_count = 0
    for line in data:gmatch("[^\r\n]+") do
        if line:find("DROP") then
            local count = line:match("^%s*(%d+)")
            if count then
                total_count = total_count + (tonumber(count) or 0)
            end
        end
    end
    return total_count
end

local function get_mangle_count()
    if file.access("/sbin/fw4") then
        local data = execute_command("nft list counter inet filter qos")
        if not data then return 0 end

        for line in data:gmatch("[^\r\n]+") do
            if line:find("packets") then
                local count = line:match("packets%s+(%d+)")
                return tonumber(count) or 0
            end
        end
        return 0
    end
    local data = execute_command("iptables -t mangle -L POSTROUTING -nvx")
    if not data then return 0 end

    for line in data:gmatch("[^\r\n]+") do
        if line:find("0x60/0xf0") then
            local count = line:match("^%s*(%d+)")
            return tonumber(count) or 0
        end
    end
    return 0
end

local function read_current_stats()
    local qos = 0
    local content_protection_day =  0
    local content_protection_all =  0
    local qos_last_date = ""
    local content_protection_last_date = ""

    local qos_conf = file.readfile(config.qos_stats_file)
    if qos_conf then
        qos = qos_conf:match("qos:(%d+)") or 0
        qos_last_date = qos_conf:match("date:(%d+-%d+-%d+)") or ""
    end

    local content_protection_conf = file.readfile(config.content_protection_stats_file)
    if content_protection_conf then
        content_protection_day = content_protection_conf:match("content_protection_day:(%d+)") or 0
        content_protection_all = content_protection_conf:match("content_protection_all:(%d+)") or 0
        content_protection_last_date = content_protection_conf:match("date:(%d+-%d+-%d+)") or ""
    end

    return {
        qos = tonumber(qos),
        content_protection_day = tonumber(content_protection_day),
        content_protection_all = tonumber(content_protection_all),
        qos_last_date = qos_last_date,
        content_protection_last_date = content_protection_last_date
    }
end

local function save_stats(qos_count, content_protection_count)
    local current_stats = read_current_stats()
    local current_date = os.date("%Y-%m-%d")

    if current_date ~= current_stats.content_protection_last_date then
        current_stats.content_protection_day = 0
        current_stats.content_protection_last_date = current_date
    end

    if current_date ~= current_stats.qos_last_date then
        current_stats.qos = 0
        current_stats.qos_last_date = current_date
    end

    if qos_count > 0 then
        current_stats.qos = current_stats.qos + qos_count
    end

    if content_protection_count > 0 then
        current_stats.content_protection_day = current_stats.content_protection_day + content_protection_count
        current_stats.content_protection_all = current_stats.content_protection_all + content_protection_count
    end

    local qos_content = string.format("qos:%d date:%s", current_stats.qos, current_date)
    local content_protection_content = string.format("content_protection_day:%d content_protection_all:%d date:%s", current_stats.content_protection_day, current_stats.content_protection_all, current_date)
    file.writefile(config.qos_stats_file, qos_content)
    file.writefile(config.content_protection_stats_file, content_protection_content)
end

local function file_exists(name)
    local f = io.open(name, "r")
    if f then
        f:close()
        return true
    else
        return false
    end
end

local function monitor_loop()
    local c = uci.cursor()
    local qos_enabled = c:get("gl_dpi_qos", "qos", "prio_enable") == "1"
    local content_protection_enabled = c:get("gl_dpi_content_protection", "content_protection", "enabled") == "1"
    c:close()

    if not file_exists(config.qos_stats_file) and file_exists(config.qos_backup_file) and qos_enabled then
        execute_command(string.format("cp %s %s", config.qos_backup_file, config.qos_stats_file))
    end

    if not file_exists(config.content_protection_stats_file) and file_exists(config.content_protection_backup_file) and content_protection_enabled then
        execute_command(string.format("cp %s %s", config.content_protection_backup_file, config.content_protection_stats_file))
    end

    local cycle_count = 0
    while true do
        c = uci.cursor()
        local qos_count = 0
        local content_protection_count = 0
        qos_enabled = c:get("gl_dpi_qos", "qos", "prio_enable") == "1"
        content_protection_enabled = c:get("gl_dpi_content_protection", "content_protection", "enabled") == "1"
        c:close()

        if not qos_enabled and not content_protection_enabled then
            os.exit(0)
        end

        if qos_enabled then
            qos_count = get_mangle_count()
        end

        if content_protection_enabled then
            content_protection_count = get_parental_drop_count()
        end

        if qos_count > 0 or content_protection_count > 0 then
            save_stats(qos_count, content_protection_count)

            if qos_enabled and qos_count > 0 then
                if file.access("/sbin/fw4") then
                    execute_command("nft reset counter inet filter qos")
                else
                    execute_command("iptables -t mangle -Z POSTROUTING")
                end
            end

            if content_protection_count and content_protection_count > 0 then
                if file.access("/sbin/fw4") then
                    execute_command("nft reset counter inet filter block")
                else
                    execute_command("iptables -Z parental_control")
                end
            end
        end

        cycle_count = cycle_count + 1
        local cycles_per_hour = config.backup_interval / config.interval
        if cycle_count >= cycles_per_hour then
            execute_command(string.format("cp %s %s", config.qos_stats_file, config.qos_backup_file))
            execute_command(string.format("cp %s %s", config.content_protection_stats_file, config.content_protection_backup_file))
            cycle_count = 0
        end

        eco.sleep(config.interval)
    end
end

local function main()
    local success, err = pcall(monitor_loop)
    if not success then
        log.err("stats.lua err : " .. tostring(err))
    end
end

main()
