#!/usr/bin/lua

local uci = require "uci"
local fs = require "oui.fs"

-- 获取现有实例配置信息
local function get_existing_instances()
    local cursor = uci.cursor()
    local instances = {}

    -- 收集network配置
    cursor:foreach("network", "interface", function(s)
        if (s[".name"]:match("^wgclient%d+$") or s[".name"]:match("^ovpnclient%d+$"))
           and s.proto and s.config then
            instances[s[".name"]] = {
                proto = s.proto,
                config = s.config,
                group_id = nil,
                peer_id = nil
            }

            -- 解析config获取group_id和peer_id
            if s.proto == "wgclient" then
                instances[s[".name"]].peer_id = s.config:match("peer_(%d+)")
            else
                instances[s[".name"]].group_id, instances[s[".name"]].peer_id = s.config:match("(%d+)_(%d+)")
            end
        end
    end)

    return instances
end

-- 检查是否为特殊类型
local function is_special_via_type(via_type)
    return  via_type == "novpn"
end

-- 查找匹配的现有实例
local function find_matching_instance(existing_instances, rule)
    for via, instance in pairs(existing_instances) do
        if rule.via_type == "wireguard" and
           instance.peer_id == rule.peer_id then
            print(string.format("Found matching instance %s for rule peer: %s", via, rule.peer_id))
            return via
        elseif rule.via_type == "openvpn" and
               instance.group_id == rule.group_id and
               instance.peer_id == rule.peer_id then
            print(string.format("Found matching instance %s for rule config: %s_%s",
                via, rule.group_id, rule.peer_id))
            return via
        end
    end
    return nil
end

-- 找到可用的实例索引
local function find_available_index(existing_instances, via_type)
    if is_special_via_type(via_type) then
        return nil
    end

    local prefix = via_type == "wireguard" and "wgclient" or "ovpnclient"
    local used_indices = {}

    -- 收集已使用的索引
    for via, _ in pairs(existing_instances) do
        local index = tonumber(via:match(prefix .. "(%d+)"))
        if index then
            used_indices[index] = true
        end
    end

    -- 找到最小的可用索引
    local MIN_INDEX = 1
    local MAX_INDEX = 5
    for i = MIN_INDEX, MAX_INDEX do
        if not used_indices[i] then
            return i
        end
    end
    return nil
end

-- 执行setup_instance命令
local function execute_setup_instance(operation, via, group_id, peer_id)
    local cmd = string.format("/usr/bin/setup_instance %s %s", operation, via)
    if group_id then cmd = cmd .. " " .. group_id end
    if peer_id then cmd = cmd .. " " .. peer_id end

    local ret = os.execute(cmd)
    if ret ~= 0 then
        print(string.format("Failed to execute: %s", cmd))
    end
    return ret == 0
end

local function is_instance_config_used(instance, rules)
    for _, rule in pairs(rules) do
        if rule.via_type == "wireguard" and instance.peer_id == rule.peer_id then
            return true
        elseif rule.via_type == "openvpn" and
               instance.group_id == rule.group_id and
               instance.peer_id == rule.peer_id then
            return true
        end
    end
    return false
end

-- 清理未使用的实例
local function clean_unused_instances(existing_instances, rules)
    for via, instance in pairs(existing_instances) do
        if not is_instance_config_used(instance, rules) then
            print(string.format("Cleaning unused instance: %s", via))
            execute_setup_instance("stop", via)
            execute_setup_instance("clean", via)
            -- 从existing_instances中删除
            existing_instances[via] = nil
        end
    end
end

-- 检查实例是否需要启用
local function should_enable_instance(rules_for_via)
    for _, rule in pairs(rules_for_via) do
        if rule.enabled == "1" then
            return true
        end
    end
    return false
end

local function handle_rule_options()
    local c = uci.cursor()
    local vias = {}
    local configed_instances = {}

    c:foreach("route_policy", "rule", function(s)
        if s.via then
            vias[#vias+1] = s.via
        end

        if s.enabled == "0" or (not s.mtu and not s.masq and not s.local_access) or not s.via or configed_instances[s.via] then
            c:set("route_policy", s[".name"], "options_in_used", "0")
            return
        end

        if s.masq then
            c:set("network", s.via, "modified_masq_value", s.masq)
        else
            c:delete("network", s.via, "modified_masq_value")
        end

        if s.local_access then
            c:set("network", s.via, "modified_local_access", s.local_access)
        else
            c:delete("network", s.via, "modified_local_access")
        end

        if s.mtu then
            c:set("network", s.via, "mtu", s.mtu)
        else
            c:delete("network", s.via, "mtu")
        end

        configed_instances[s.via] = true
        c:set("route_policy", s[".name"], "options_in_used", "1")
    end)

    for _, via in ipairs(vias) do
        if not configed_instances[via] then
            c:delete("network", via, "mtu")
            c:delete("network", via, "modified_masq_value")
            c:delete("network", via, "modified_local_access")
        end
    end

    c:commit("network")
    c:commit("route_policy")
end

-- 处理单个规则
local function process_rule(name, rule, existing_instances, via_rules)
    if is_special_via_type(rule.via_type) then
        local cursor = uci.cursor()
        cursor:set("route_policy", name, "via", rule.via_type)
        cursor:commit("route_policy")
        return
    end

    -- 查找匹配的现有实例
    local matched_via = find_matching_instance(existing_instances, rule)
    if matched_via then
        rule.via = matched_via
    else
        -- 创建新实例
        local index = find_available_index(existing_instances, rule.via_type)
        if index and rule.enabled == "1" then
            rule.via = (rule.via_type == "wireguard" and "wgclient" or "ovpnclient") .. index
        end
    end

    if rule.via then
        local cursor = uci.cursor()
        cursor:set("route_policy", name, "via", rule.via)
        cursor:commit("route_policy")

        -- 添加到via_rules映射
        if not via_rules[rule.via] then
            via_rules[rule.via] = {}
        end
        via_rules[rule.via][name] = rule

        -- 配置实例
        local existing = existing_instances[rule.via]
        if not existing and rule.enabled == "1" then
            print(string.format("Creating new instance %s for rule %s", rule.via, rule.name or name))
            execute_setup_instance("generate", rule.via, rule.group_id, rule.peer_id)
            -- 将新创建的实例添加到existing_instances中，避免同一次执行中重复创建
            existing_instances[rule.via] = {
                proto = rule.via_type == "wireguard" and "wgclient" or "ovpnclient",
                config = rule.via_type == "wireguard" and ("peer_" .. rule.peer_id) or (rule.group_id .. "_" .. rule.peer_id),
                group_id = rule.group_id,
                peer_id = rule.peer_id
            }
        end
    end
end

local function main()
    local rules_array = {}  -- 有序数组保存规则
    local rules_map = {}    -- 映射表便于查找
    local existing_instances = get_existing_instances()
    local cursor = uci.cursor()
    local is_tap_s2s = cursor:get("route_policy", "global", "is_tap_s2s")
    local is_tap_s2s_mode = false
    if is_tap_s2s ~= nil then
        is_tap_s2s_mode = is_tap_s2s == "1"
    else
        local config = cursor:get("network", "ovpnclient", "config")
        if config and cursor:get("ovpnclient", config, "mode") == "tap-s2s" then
            is_tap_s2s_mode = true
        end
    end

    -- 按配置文件中的顺序收集所有规则
    cursor:foreach("route_policy", "rule", function(section)
        if section.via_type then
            local rule = {
                via_type = section.via_type == "autovpn" and (section.peer_id and "wireguard" or "openvpn") or section.via_type,
                group_id = section.group_id,
                peer_id = section.peer_id or section.client_id,
                via = section.via,
                enabled = tostring(section.enabled or "0"),
                name = section.name,
                config_name = section[".name"]
            }
            table.insert(rules_array, rule)  -- 按顺序添加到数组
            rules_map[section[".name"]] = rule  -- 同时添加到映射表
        end
    end)

    -- 收集实例和规则的映射关系
    local via_rules = {}

    -- 先清理未使用的实例
    clean_unused_instances(existing_instances, rules_map)

    -- 按配置文件中的顺序处理每条规则
    for _, rule in ipairs(rules_array) do
        process_rule(rule.config_name, rule, existing_instances, via_rules)
    end

    -- 根据规则状态设置实例状态，实例在所有规则里都关闭，才关闭实例
    local any_instance_enabled = false

    -- 创建有序的via数组
    local via_array = {}
    local via_set = {}  -- 用于快速查找

    -- 按规则的顺序收集via
    for _, rule in ipairs(rules_array) do
        if rule.via and not via_set[rule.via] then
            table.insert(via_array, rule.via)
            via_set[rule.via] = true
        end
    end

    -- 按收集到的顺序启动实例
    for _, via in ipairs(via_array) do
        local rules_for_via = via_rules[via]
        if rules_for_via and should_enable_instance(rules_for_via) then
            if is_tap_s2s_mode then
                print(string.format("Stopping instance %s (tap-s2s mode)", via))
                execute_setup_instance("stop", via)
            else
                print(string.format("Starting instance %s (has enabled rules)", via))
                execute_setup_instance("start", via)
                any_instance_enabled = true
            end
        else
            print(string.format("Stopping instance %s (all rules disabled)", via))
            execute_setup_instance("stop", via)
        end
    end

    -- 设置 route_policy.global.instance_on标记有实例是打开的
    cursor:set("route_policy", "global", "instance_on", any_instance_enabled and "1" or "0")

    -- 设置 route_policy.global.enabled，当有实例打开或者默认隧道关闭（即兜底killswitch）时，设置为1，否则设置为0
    local default_enabled = cursor:get("route_policy", "@default[0]", "enabled")
    if is_tap_s2s_mode then
        cursor:set("route_policy", "global", "enabled", "0")
    else
        cursor:set(
            "route_policy",
            "global",
            "enabled",
            (default_enabled == "0" or any_instance_enabled) and "1" or "0"
        )
    end

    cursor:commit("route_policy")

    handle_rule_options()

    fs.sync()
end

main()
