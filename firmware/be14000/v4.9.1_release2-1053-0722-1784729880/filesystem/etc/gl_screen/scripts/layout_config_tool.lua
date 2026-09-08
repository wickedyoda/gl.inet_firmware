local script_path = arg[0]
local script_dir = script_path:match("(.*[/\\])") or "."
package.path = package.path .. ";" .. script_dir .. "/?.lua"

local lfs = require "lfs"
local kv_config = require "kv_config"

local STYPE = kv_config.STYPE
local REAL_ISSUE = {
    GAP = true,
    UNUSED_KEY = true,
    CHAIN_INVALID = true
}

local function join_path(...)
    local parts = {...}
    local out = {}
    for i = 1, #parts do
        local part = tostring(parts[i])
        if part ~= "" then
            part = part:gsub("/+$", "")
            part = part:gsub("^/+", "")
            out[#out + 1] = part
        end
    end
    local prefix = tostring(parts[1]):sub(1, 1) == "/" and "/" or ""
    return prefix .. table.concat(out, "/")
end

local function abs_path(path)
    if path:sub(1, 1) == "/" then
        return path
    end
    return join_path(lfs.currentdir(), path)
end

local function parent_dir(path)
    local parent = path:match("(.+)/[^/]+$")
    if parent then
        return parent
    end
    return "."
end

local function dir_exists(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "directory"
end

local function file_exists(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file"
end

local function read_all(path)
    local f = io.open(path, "rb")
    local content = f:read("*a")
    f:close()
    return content
end

local function write_all(path, content)
    local f = io.open(path, "wb")
    f:write(content)
    f:close()
end

local function mkdir_p(path)
    if path == "" or path == "." then
        return
    end
    local current = ""
    if path:sub(1, 1) == "/" then
        current = "/"
    end
    for part in path:gmatch("[^/]+") do
        if current == "" then
            current = part
        elseif current == "/" then
            current = current .. part
        else
            current = current .. "/" .. part
        end
        lfs.mkdir(current)
    end
end

local function sorted_keys(map)
    local keys = {}
    for key, _ in pairs(map) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function is_comment_key(key)
    return key:sub(1, 2) == "//"
end

local function keep_valid_entries(data)
    local filtered = {}
    for key, node in pairs(data) do
        if not is_comment_key(key) then
            filtered[key] = node
        end
    end
    return filtered
end

local function parse_screen_mk(path)
    local conf = {}
    for line in io.lines(path) do
        local key, value = line:match("^%s*([A-Za-z0-9_]+)%s*:?=%s*([^#%s]+)")
        if key and value then
            conf[key] = value
        end
    end
    return conf
end

local function list_subdirs(path)
    local dirs = {}
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = join_path(path, entry)
            if dir_exists(full_path) then
                dirs[#dirs + 1] = entry
            end
        end
    end
    table.sort(dirs)
    return dirs
end

local function build_config_maps(config_root)
    local dir_names = list_subdirs(config_root)
    local dir_set = {}
    local mk_map = {}
    local products = {}

    for _, dir_name in ipairs(dir_names) do
        dir_set[dir_name] = true
        local mk_path = join_path(config_root, dir_name, "screen.mk")
        if file_exists(mk_path) then
            local mk_conf = parse_screen_mk(mk_path)
            mk_map[dir_name] = mk_conf
            if mk_conf.GL_USE_SCREEN then
                products[#products + 1] = dir_name
            end
        end
    end

    table.sort(products)
    return dir_set, mk_map, products
end

local function collect_use_targets(conf)
    local seen = {}
    local targets = {}
    for key, value in pairs(conf) do
        if key:match("^GL_USE_") and value and value ~= "" and not seen[value] then
            seen[value] = true
            targets[#targets + 1] = value
        end
    end
    table.sort(targets)
    return targets
end

local function resolve_next_layer(current, mk_map)
    local conf = mk_map[current]
    if not conf then
        return nil, nil
    end

    local candidates = collect_use_targets(conf)

    if #candidates == 0 then
        return nil, nil
    end
    if #candidates > 1 then
        return nil, "NEXT_LAYER_CONFLICT"
    end
    return candidates[1], nil
end

local function build_chain(product, mk_map, dir_set)
    local forward = {product}
    local visited = {
        [product] = true
    }
    local current = product

    while true do
        local next_layer, next_err = resolve_next_layer(current, mk_map)
        if next_err then
            return nil, next_err
        end
        if not next_layer then
            break
        end
        if not dir_set[next_layer] then
            return nil, "NEXT_LAYER_MISSING"
        end
        if visited[next_layer] then
            return nil, "CHAIN_CYCLE"
        end
        visited[next_layer] = true
        forward[#forward + 1] = next_layer
        current = next_layer
    end

    local chain = {}
    for i = #forward, 1, -1 do
        chain[#chain + 1] = forward[i]
    end
    return chain, nil
end

local function load_layout_layers(config_root, chain, dim)
    local layers = {}
    for i, layer_name in ipairs(chain) do
        local path = join_path(config_root, layer_name, dim, "layout")
        local exists = file_exists(path)
        local data = {}
        if exists then
            data = kv_config.parse_file(path)
            data = keep_valid_entries(data)
        end
        layers[i] = {
            name = layer_name,
            path = path,
            exists = exists,
            data = data
        }
    end
    return layers
end

local function collect_keys(layers)
    local key_set = {}
    for _, layer in ipairs(layers) do
        for key, _ in pairs(layer.data) do
            key_set[key] = true
        end
    end
    return key_set
end

local function is_gap_pattern(layers, key)
    local first = nil
    local last = nil
    local count = 0

    for idx, layer in ipairs(layers) do
        if layer.data[key] then
            count = count + 1
            if not first then
                first = idx
            end
            last = idx
        end
    end

    if count == 0 then
        return false
    end
    return first ~= 1 or count ~= last
end

local function collect_existing_nodes(layers, key)
    local nodes = {}
    for _, layer in ipairs(layers) do
        local node = layer.data[key]
        if node then
            nodes[#nodes + 1] = {
                type = node.type,
                value = node.value
            }
        end
    end
    return nodes
end

local function apply_compact_prefix(layers, key, nodes)
    for idx, layer in ipairs(layers) do
        if idx <= #nodes then
            layer.data[key] = {
                type = nodes[idx].type,
                value = nodes[idx].value
            }
        else
            layer.data[key] = nil
        end
    end
end

local function remove_key_from_layers(layers, key)
    for _, layer in ipairs(layers) do
        layer.data[key] = nil
    end
end

local function format_value(node)
    if node.type == STYPE.NULL then
        return "NULL"
    end
    if node.type == STYPE.INTEGER then
        return tostring(node.value)
    end
    if node.type == STYPE.FLOAT then
        return string.format("%.12g", node.value)
    end
    if node.type == STYPE.STRING then
        return '"' .. tostring(node.value) .. '"'
    end
    if node.type == STYPE.POINTER then
        return "&" .. tostring(node.value)
    end
    return tostring(node.value)
end

local function serialize_layout(data)
    local keys = sorted_keys(data)
    local lines = {}
    for _, key in ipairs(keys) do
        lines[#lines + 1] = key .. " " .. format_value(data[key])
    end
    if #lines == 0 then
        return ""
    end
    return table.concat(lines, "\n") .. "\n"
end

local function write_layer_if_changed(layer)
    local new_content = serialize_layout(layer.data)
    local old_content = ""
    if layer.exists then
        old_content = read_all(layer.path)
    end
    if new_content == old_content then
        return false
    end
    mkdir_p(parent_dir(layer.path))
    write_all(layer.path, new_content)
    layer.exists = true
    return true
end

local function collect_source_files(dir_path, files)
    for entry in lfs.dir(dir_path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = join_path(dir_path, entry)
            local attr = lfs.attributes(full_path)
            if attr and attr.mode == "directory" then
                collect_source_files(full_path, files)
            elseif attr and attr.mode == "file" and (entry:match("%.c$") or entry:match("%.h$")) then
                files[#files + 1] = full_path
            end
        end
    end
end

local function extract_source_strings(path, str_set)
    local content = read_all(path)
    for str in content:gmatch('"([^"\n]*)"') do
        if str ~= "" then
            str_set[str] = true
        end
    end
end

local function build_source_checker(source_root)
    local main_dir = join_path(source_root, "main")
    local boot_dir = join_path(source_root, "boot")

    if not dir_exists(main_dir) or not dir_exists(boot_dir) then
        return {
            enabled = false,
            str_set = {}
        }
    end

    local files = {}
    local str_set = {}
    collect_source_files(main_dir, files)
    collect_source_files(boot_dir, files)

    for _, path in ipairs(files) do
        extract_source_strings(path, str_set)
    end

    return {
        enabled = true,
        str_set = str_set
    }
end

local function skip_unused_check_for_key(key)
    return key:match("_LABEL_SIZE$") ~= nil or key:match("_LABEL_FONT$") ~= nil
end

local function is_key_used(checker, key)
    return checker.str_set[key]
end

local function init_product_report(product, chain)
    return {
        product = product,
        chain = chain,
        issues = {},
        changed_files = 0
    }
end

local function append_issue(report, dim, key, issue_type, action)
    report.issues[#report.issues + 1] = {
        dim = dim,
        key = key,
        issue_type = issue_type,
        action = action
    }
end

local function process_dimension(mode, checker, config_root, chain, dim, report)
    local layers = load_layout_layers(config_root, chain, dim)
    local key_set = collect_keys(layers)
    local keys = sorted_keys(key_set)

    for _, key in ipairs(keys) do
        local has_gap = is_gap_pattern(layers, key)
        if has_gap then
            append_issue(report, dim, key, "GAP", mode == "fix" and "COMPACT_PREFIX" or "-")
            if mode == "fix" then
                local nodes = collect_existing_nodes(layers, key)
                apply_compact_prefix(layers, key, nodes)
            end
        end

        if checker.enabled and not skip_unused_check_for_key(key) and not is_key_used(checker, key) then
            append_issue(report, dim, key, "UNUSED_KEY", mode == "fix" and "DELETE_KEY" or "-")
            if mode == "fix" then
                remove_key_from_layers(layers, key)
            end
        end
    end

    if mode == "fix" then
        for _, layer in ipairs(layers) do
            if write_layer_if_changed(layer) then
                report.changed_files = report.changed_files + 1
            end
        end
    end
end

local function print_report(reports)
    local real_issue_count = 0
    local changed_count = 0

    for _, report in ipairs(reports) do
        local chain_text = "-"
        if report.chain and #report.chain > 0 then
            chain_text = table.concat(report.chain, "->")
        end
        print("PRODUCT " .. report.product .. " CHAIN " .. chain_text)
        if #report.issues == 0 then
            print("  RESULT OK")
        else
            for _, issue in ipairs(report.issues) do
                print(string.format("  dim=%s key=%s type=%s action=%s", issue.dim, issue.key, issue.issue_type,
                    issue.action))
                if REAL_ISSUE[issue.issue_type] then
                    real_issue_count = real_issue_count + 1
                end
            end
        end
        if report.changed_files > 0 then
            print("  changed_files=" .. report.changed_files)
            changed_count = changed_count + report.changed_files
        end
    end

    print(string.format("SUMMARY real_issues=%d changed_files=%d", real_issue_count, changed_count))
    return real_issue_count
end

local function usage()
    print("Usage: lua layout_config_tool.lua <check|fix> [config_dir]")
end

local function run(mode, config_root, source_root)
    local checker = build_source_checker(source_root)
    local dir_set, mk_map, products = build_config_maps(config_root)
    local reports = {}

    if #products == 0 then
        print("No product entry found")
        return 0
    end

    for _, product in ipairs(products) do
        local chain, chain_err = build_chain(product, mk_map, dir_set)
        local report = init_product_report(product, chain)

        if not checker.enabled then
            append_issue(report, "-", "-", "SKIP_SOURCE_CHECK", "-")
        end

        if chain_err then
            append_issue(report, "-", "-", "CHAIN_INVALID", chain_err)
            reports[#reports + 1] = report
        else
            process_dimension(mode, checker, config_root, chain, "dpr", report)
            process_dimension(mode, checker, config_root, chain, "ndpr", report)
            reports[#reports + 1] = report
        end
    end

    local real_issue_count = print_report(reports)
    if mode == "check" and real_issue_count > 0 then
        return 1
    end
    return 0
end

local function main()
    local mode = arg[1]
    local config_dir_arg = arg[2]
    local cwd = lfs.currentdir()

    if mode ~= "check" and mode ~= "fix" then
        usage()
        os.exit(2)
    end

    local config_root
    local source_root = cwd

    if config_dir_arg then
        config_root = abs_path(config_dir_arg)
    else
        config_root = join_path(cwd, "config")
    end

    if not dir_exists(config_root) then
        print("config_dir not found: " .. config_root)
        os.exit(2)
    end

    local code = run(mode, config_root, source_root)
    os.exit(code)
end

main()
