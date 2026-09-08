local uci = require "uci"
local fs = require "oui.fs"
local utils = require "oui.utils"
local cjson = require "cjson"

local c = uci.cursor()

local function is_valid_ip(ip)
    if not ip or type(ip) ~= "string" then
        return false
    end

    local pattern = "^(%d+)%.(%d+)%.(%d+)%.(%d+)$"
    local p1, p2, p3, p4 = ip:match(pattern)

    if p1 and p2 and p3 and p4 then
        p1, p2, p3, p4 = tonumber(p1), tonumber(p2), tonumber(p3), tonumber(p4)
        if p1 and p2 and p3 and p4 then
            return p1 <= 255 and p2 <= 255 and p3 <= 255 and p4 <= 255
        end
    end

    return false
end

local function is_valid_cidr(cidr)
    if not cidr or type(cidr) ~= "string" then
        return false
    end

    local pattern = "^(%d+%.%d+%.%d+%.%d+)/(%d+)$"
    local ip_part, mask_part = cidr:match(pattern)

    if ip_part and mask_part then
        mask_part = tonumber(mask_part)
        return is_valid_ip(ip_part) and mask_part and mask_part >= 0 and mask_part <= 32
    end

    return false
end

local function execute_command(cmd)
    local handle = io.popen(cmd .. " 2>/dev/null")
    if handle then
        local result = handle:read("*a")
        handle:close()
        return result
    end
    return nil
end

local function get_apps()
    local apps = {}
    local c = uci.cursor()
    local result = {}
    local conf_content = utils.readfile("/etc/netifyd/netify-apps.conf")
    if not conf_content then
        return nil, "not find netify-apps.conf"
    end

    for line in conf_content:gmatch("[^\r\n]+") do
        local id, name = line:match("app:(%d+):([%w%._-]+)")
        if id and name then
            name = name:gsub("^netify%.", "")
            apps[id] = {
                name = name
            }
        end
    end

    local json_content = utils.readfile("/etc/netifyd/netify-categories.json")
    if not json_content then
        return nil, "not find netify-categories.json"
    end

    local success, data = pcall(cjson.decode, json_content)
    if not success then
        return nil, "JSON decode error"
    end

    local dangerous_website_data = {
        name = "dangerous_website",
        small_cats = {},
        apps = {}
    }

    c:foreach("gl_category", "netifyd", function(s)
        if s.category then
            local big_category_name = s[".name"]

            if big_category_name == "dangerous_website" then
                for _, small_cat in ipairs(s.category) do
                    dangerous_website_data.small_cats[small_cat] = true
                    result[#result + 1] = {
                        category_name = small_cat,
                        apps = {}
                    }
                end
            end
        end
    end)

    if not next(dangerous_website_data.small_cats) then
        return {}
    end

    local small_category_to_apps = {}
    local category_tag_index = data.application_tag_index or {}
    local application_index = data.application_index or {}

    for _, item in ipairs(application_index) do
        local cat_id = tostring(item[1])
        local app_ids = item[2] or {}

        local small_category_name = "unknown"
        for tag, id in pairs(category_tag_index) do
            if tostring(id) == cat_id then
                small_category_name = tag:gsub("^netify%.", "")
                break
            end
        end

        if dangerous_website_data.small_cats[small_category_name] then
            small_category_to_apps[small_category_name] = small_category_to_apps[small_category_name] or {}
            for _, app_id in ipairs(app_ids) do
                local id_str = tostring(app_id)
                if apps[id_str] then
                    small_category_to_apps[small_category_name][#small_category_to_apps[small_category_name] + 1] = apps[id_str]
                end
            end
        end
    end

    for _, res_item in ipairs(result) do
        local small_cat = res_item.category_name
        if small_category_to_apps[small_cat] then
            local unique_apps = {}
            local app_set = {}
            for _, app_obj in ipairs(small_category_to_apps[small_cat]) do
                if not app_set[app_obj.name] then
                    unique_apps[#unique_apps + 1] = app_obj
                    app_set[app_obj.name] = true
                end
            end
            res_item.apps = unique_apps
        end
    end

    return result
end

local function add_block_ip()
    local dnsmasq_conf = "/var/run/dnsmasq/gl_dpi.conf"
    local use_nft = fs.access("/sbin/fw4")
    local dnsmasq_enabled = fs.access("/etc/init.d/dnsmasq")
    local dnsmasq_main_conf = "/etc/dnsmasq.conf"
    local conf_file_line = "conf-file=/var/run/dnsmasq/gl_dpi.conf\n"

    if use_nft then
        execute_command("nft flush set inet filter GL_DPI_BLOCK")
    else
        execute_command("ipset flush GL_DPI_BLOCK")
    end

    utils.writefile(dnsmasq_conf, "")

    local enabled = c:get("gl_dpi_content_protection", "content_protection", "enabled")
    if enabled ~= "1" then
        if dnsmasq_enabled then
            local content = utils.readfile(dnsmasq_main_conf) or ""
            local new_content = content:gsub("conf%-file=/var/run/dnsmasq/gl_dpi.conf\n", "")
            if new_content ~= content then
                utils.writefile(dnsmasq_main_conf, new_content)
            end
            execute_command("/etc/init.d/dnsmasq restart")
        end
        return
    end

    local ip_list = c:get("gl_dpi_content_protection", "content_protection", "domain")
    local conf_content = ""
    local prefix = use_nft and "nftset=/" or "ipset=/"
    local suffix = use_nft and "/4#inet#filter#GL_DPI_BLOCK" or "/GL_DPI_BLOCK"

    if ip_list and ip_list ~= "" then
        local ip_entries = {}
        local domain_entries = {}

        for _, item in ipairs(ip_list) do
            if is_valid_cidr(item) or is_valid_ip(item) then
                ip_entries[#ip_entries + 1] = item
            else
                domain_entries[#domain_entries + 1] = item
            end
        end

        if #ip_entries > 0 then
            if use_nft then
                local nft_cmd = 'nft add element inet filter GL_DPI_BLOCK { '
                for i, ip in ipairs(ip_entries) do
                    nft_cmd = nft_cmd .. (i > 1 and ", " or "") .. ip
                end
                nft_cmd = nft_cmd .. ' }'
                execute_command(nft_cmd)
            else
                local ipset_restore_cmd = "create GL_DPI_BLOCK hash:net family inet hashsize 1024 maxelem 65536\n"
                for _, ip in ipairs(ip_entries) do
                    ipset_restore_cmd = ipset_restore_cmd .. string.format('add GL_DPI_BLOCK %s\n', ip)
                end
                local tmp_file = "/tmp/ipset_restore.txt"
                utils.writefile(tmp_file, ipset_restore_cmd)
                execute_command(string.format('ipset restore -! < %s', tmp_file))
                os.remove(tmp_file)
            end
        end

        if #domain_entries > 0 then
            for _, domain in ipairs(domain_entries) do
                if not domain:find("%*") and #domain > 0 then
                    conf_content = conf_content .. prefix .. domain .. suffix .. "\n"
                end
            end
        end
    end

    local app_list = c:get("gl_dpi_content_protection", "content_protection", "app") or {}
    local category_list = c:get("gl_dpi_content_protection", "content_protection", "category") or {}

    if #category_list > 0 then
        local all_apps = get_apps()

        local category_map = {}
        for _, category in ipairs(category_list) do
            category_map[category] = true
        end

        local apps_from_categories = {}
        for _, tmp in ipairs(all_apps or {}) do
            if category_map[tmp.category_name] then
                for _, app in ipairs(tmp.apps or {}) do
                    apps_from_categories[app.name] = true
                end
            end
        end

        for app_name in pairs(apps_from_categories) do
            app_list[#app_list + 1] = app_name
        end
    end

    if app_list and app_list ~= "" then
        local target_apps = {}

        for _, app in ipairs(app_list) do
            target_apps[app] = true
        end

        if fs.access("/etc/netifyd/netify-apps.conf") then
            local file_content = utils.readfile("/etc/netifyd/netify-apps.conf") or ""
            local app_id_to_name = {}
            local app_config_lines = {}
            local seen_domains = {}

            for line in file_content:gmatch("[^\r\n]+") do
                local parts = {}
                for part in line:gmatch("[^:]+") do
                    parts[#parts + 1] = part
                end

                if #parts >= 3 then
                    if parts[1] == "app" then
                        local app_name = parts[3]:gsub("^netify%.", "")
                        if target_apps[app_name] then
                            app_id_to_name[parts[2]] = app_name
                        end
                    elseif parts[1] == "dom" and app_id_to_name[parts[2]] then
                        local domain = parts[3]
                        if not seen_domains[domain] then
                            seen_domains[domain] = true
                            app_config_lines[#app_config_lines + 1] = prefix .. domain .. suffix
                        end
                    end
                end
            end

            if #app_config_lines > 0 then
                conf_content = conf_content .. table.concat(app_config_lines, "\n") .. "\n"
            end
        end
    end

    if conf_content ~= "" then
        utils.writefile(dnsmasq_conf, conf_content)
    end

    if fs.access(dnsmasq_main_conf) then
        local content = utils.readfile(dnsmasq_main_conf) or ""
        if not content:find(conf_file_line, 1, true) then
            utils.writefile(dnsmasq_main_conf, conf_file_line, true)
        end
    end

    if dnsmasq_enabled and conf_content ~= "" then
        execute_command("/etc/init.d/dnsmasq restart")
    end
end

local function main()
    local content = utils.readfile("/etc/dnsmasq.conf") or ""
    local new_content = content:gsub("conf%-file=/tmp/dnsmasq.d/gl_dpi.conf[^\n]*\n?", "")
    if new_content ~= content then
        utils.writefile("/etc/dnsmasq.conf", new_content)
    end

    if fs.access("/etc/config/gl_dpi_content_protection") then
        local config_section = c:get("gl_dpi_content_protection", "content_protection")
        if config_section then
            add_block_ip()
        end
    end
end

main()
