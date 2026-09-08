#!/usr/bin/lua

-- 调试开关
local DEBUG = false

-- 调试打印函数
local function debug_print(format, ...)
    if DEBUG then
        print(string.format(format, ...))
    end
end

local uci = require("uci")

-- 获取默认规则的 via
local cursor = uci.cursor()
local default_via = "novpn"  -- 默认值
cursor:foreach("route_policy", "default", function(section)
    if section.enabled == "1" and section.via then
        default_via = section.via
        return false  -- 找到第一个启用的默认规则就停止
    end
end)

local use_fw4 = false
if uci.cursor():get("route_policy", "global", "use_fw4") == '1' then
    use_fw4 = true
end

-- 读取域名列表文件
local function read_domain_list(file_path)
    if not file_path then return {} end

    local domains = {}
    local file = io.open(file_path, "r")
    if file then
        for line in file:lines() do
            line = line:gsub("%s*#.*$", ""):gsub("^%s*(.-)%s*$", "%1")
            if line ~= "" and not line:match("^%d+%.%d+%.%d+%.%d+") and not line:match("^[%w:]*:[%w:]+") then
                domains[line] = true
            end
        end
        file:close()
    end
    return domains
end

-- 获取规则中的所有域名
local function get_rule_domains(rule)
    local domains = {}

    -- 处理直接配置的域名
    if rule.to_domain_ip then
        local domain_list = type(rule.to_domain_ip) == "table" and rule.to_domain_ip or {rule.to_domain_ip}
        for _, domain in ipairs(domain_list) do
            if not domain:match("^%d+%.%d+%.%d+%.%d+") and not domain:match("^[%w:]*:[%w:]+") then
                domains[domain] = true
            end
        end
    end

    -- 处理外部文件中的域名
    if rule.to_list_external then
        local file_domains = read_domain_list(rule.to_list_external)
        for domain, _ in pairs(file_domains) do
            domains[domain] = true
        end
    end

    return domains
end

-- 写入dnsmasq配置（共享文件写法）
local function write_dnsmasq_config(domain, ipsets)
    -- 共享写法：无论 via 为何，始终写入共享文件 /var/run/dnsmasq/via_domain
    -- 其他实例目录使用符号链接指向该共享文件
    local v6_enabled = cursor:get("glipv6", "globals", "enabled") or nil
    local config_dir = "/var/run/dnsmasq"
    debug_print("Debug - Writing to shared directory: %s", config_dir)

    -- 确保共享目录存在
    os.execute("mkdir -p " .. config_dir)
    local file = io.open(config_dir .. "/via_domain", "a")

    if not file then
        print(string.format("Error - Failed to open file: %s/via_domain", config_dir))
        return
    end

    local ipset_str = table.concat(ipsets, ",")
    debug_print("Debug - Writing rule: domain=%s ipset=%s", domain, ipset_str)

    local ipset_str_fw4 = ""
    if use_fw4 then
        for _,v in ipairs(ipsets) do
            if v and v ~= "" then
                if ipset_str_fw4 ~= "" then
                    ipset_str_fw4 = ipset_str_fw4..","
                end
                ipset_str_fw4 = ipset_str_fw4.."4#inet#vpn_table#"..v
            end
        end
        ipset_str = ipset_str_fw4
    end

    if v6_enabled == "1" then
        local ipset_str_6 = ""
        for _,v in ipairs(ipsets) do
            if v and v ~= "" then
                if ipset_str_6 ~= "" then
                    ipset_str_6 = ipset_str_6..","
                end
                if use_fw4 then
                    ipset_str_6 = ipset_str_6.."6#inet#vpn_table#"..v.."_6"
                else
                    ipset_str_6 = ipset_str_6..v.."_6"
                end
            end
        end
        ipset_str = ipset_str..","..ipset_str_6
    end

    if use_fw4 then
        file:write(string.format("nftset=/%s/%s\n", domain, ipset_str))
    else
        file:write(string.format("ipset=/%s/%s\n", domain, ipset_str))
    end
    file:close()
end

-- 为每个实例目录创建共享文件的符号链接
local function ensure_symlinks(via_set)
    local shared_dir = "/var/run/dnsmasq"
    local shared_file = shared_dir .. "/via_domain"
    -- 确保共享目录与共享文件存在（若不存在则创建空文件）
    os.execute("mkdir -p '" .. shared_dir .. "'")
    do
        local f = io.open(shared_file, "a")
        if f then f:close() end
        os.execute("chmod 0644 '" .. shared_file .. "'")
    end

    -- 基础目录也建立一个软链接，便于默认实例直接引用
    os.execute("mkdir -p /tmp/dnsmasq.d")
    os.execute("ln -sf '" .. shared_file .. "' '/tmp/dnsmasq.d/via_domain'")
    debug_print("Debug - Symlink %s -> %s", "/tmp/dnsmasq.d/via_domain", shared_file)

    -- 为每个实例目录创建软链接
    for via in pairs(via_set) do
        if via and via ~= "" and via ~= "novpn" then
            local dir = "/tmp/dnsmasq.d." .. via
            os.execute("mkdir -p '" .. dir .. "'")
            local link_path = dir .. "/via_domain"
            os.execute("ln -sf '" .. shared_file .. "' '" .. link_path .. "'")
            debug_print("Debug - Symlink %s -> %s", link_path, shared_file)
        end
    end
end

-- 主函数
local function process_domain_ipsets()
    -- 清理旧的配置文件（实例目录与默认目录下的 via_domain/软链）
    os.execute("rm -f /tmp/dnsmasq.d*/via_domain")
    os.execute("rm -f /var/run/dnsmasq/via_domain")

    -- 全局收集：所有 via（含默认）与所有域名->ipset 集合
    local via_set = {}
    local domain_ipsets = {}

    cursor:foreach("route_policy", "rule", function(rule)
        if rule.enabled == "1" and (rule.to_type == "ipset" or (not rule.to_type and rule.via)) then
            debug_print("Debug - Processing rule: via=%s, to=%s", tostring(rule.via), tostring(rule.to))
            if rule.via and rule.via ~= "" then
                via_set[rule.via] = true
            end
            local rule_domains = get_rule_domains(rule)
            local ipset_name = nil
            if rule.to and rule.to ~= "" then
                ipset_name = rule.to:gsub("^!", "")
            end
            if ipset_name and ipset_name ~= "" then
                for domain, _ in pairs(rule_domains) do
                    domain_ipsets[domain] = domain_ipsets[domain] or {}
                    domain_ipsets[domain][ipset_name] = true
                    debug_print("    Domain %s needs ipset %s (via %s)", domain, ipset_name, tostring(rule.via))
                end
            end
        end
    end)

    -- 始终加入默认 via
    via_set[default_via] = true

    -- 调试输出汇总
    debug_print("\nDebug - Unified domains -> ipsets summary (global):")
    for domain, setmap in pairs(domain_ipsets) do
        local tmp = {}
        for s, _ in pairs(setmap) do table.insert(tmp, s) end
        table.sort(tmp)
        debug_print("  %s => %s", domain, table.concat(tmp, ","))
    end

    -- 确保软链接存在（指向 /var/run/dnsmasq/via_domain）
    ensure_symlinks(via_set)

    -- 写入共享 via_domain（每个域名只写一次）
    for domain, setmap in pairs(domain_ipsets) do
        local ipsets = {}
        for s in pairs(setmap) do table.insert(ipsets, s) end
        table.sort(ipsets)
        debug_print("    Writing domain %s to shared via_domain with ipsets: %s", domain, table.concat(ipsets, ","))
        write_dnsmasq_config(domain, ipsets)
    end
end

-- 执行主函数
process_domain_ipsets()
