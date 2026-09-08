local M = {}

local uci = require 'uci'
local cjson = require 'cjson'

local ETH_PORTS_JSON = '/usr/share/gl-eth-ports.json'
local MODEL_FILE = '/proc/gl-hw-info/model'
local ETH_PORTS_JSON_FALLBACKS = { './eth-ports.json', './files/eth-ports.json' }

--- 功能：读取指定路径的文件内容。
--- @param path string 文件路径
--- @param mode string|nil io.read 模式，默认 '*a'
--- @return string|nil 文件内容；打开失败时返回 nil
local function readfile(path, mode)
    local f = io.open(path, 'r')
    if not f then return nil end
    local c = f:read(mode or '*a')
    f:close()
    return c
end

--- 功能：提取并排序 table 的全部键。
--- @param t table|nil 目标 table
--- @param cmp function|nil 可选比较函数，传给 table.sort
--- @return table 键数组（已排序）
local function sorted_table_keys(t, cmp)
    local keys = {}
    for k in pairs(t or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys, cmp)
    return keys
end

--- 功能：判断端口是否具备切换为 WAN 的能力。
--- @param p table|nil 端口配置对象
--- @return boolean true 表示 support_wan=1
local function is_switchable_port(p)
    return p and tostring(p.support_wan or '0') == '1'
end

--- 功能：统计端口集合中可切换 WAN 的数量。
--- @param ports table|nil 端口配置集合
--- @return number 可切换 WAN 的端口数
local function count_switchable_ports(ports)
    local n = 0
    if not ports then return n end
    for _, p in pairs(ports) do
        if is_switchable_port(p) then
            n = n + 1
        end
    end
    return n
end

--- 功能：在基准 MAC 末段递增，生成展示/默认用 MAC（与 cable.lua 逻辑一致）。
--- @param mac string 形如 aa:bb:cc:dd:ee:ff
--- @param increment number 加到末 40 bit 的增量（非负）
--- @return string|nil
local function mac_increase(mac, increment)
    if not mac or mac == '' or increment == nil then
        return nil
    end
    local tail = mac:sub(10):gsub(':', '')
    local n = tonumber(tail, 16)
    if not n then
        return nil
    end
    return mac:sub(1, 8) .. string.format('%x', n + increment):gsub('%w%w', function(x)
        return ':' .. x
    end)
end

--- 功能：为 support_wan=1 的口写入 default_mac。
--- @param c table uci cursor
--- @param ports table collect_ports 结果
--- @return nil
local function init_default_macs(c, ports)
    local raw = readfile('/etc/board.json')
    if not raw then
        return
    end
    local ok, board = pcall(cjson.decode, raw)
    if not ok or type(board) ~= 'table' or not board.network then
        return
    end
    -- 规则（按用户约定）：
    -- - wanmac：board.network.wan.macaddr
    -- - sfp：board.network.sfp.macaddr
    -- - 剩下的一个口：board.network.secondwan.macaddr（字段缺失时回退为 base+2）
    local wan_mac = board.network.wan and board.network.wan.macaddr
    local sfp_mac = board.network.sfp and board.network.sfp.macaddr
    local secondwan_mac = board.network.secondwan and board.network.secondwan.macaddr

    -- 兜底：兼容旧 board.json（WAN 缺失时使用 LAN）。
    local base_mac = wan_mac
    if not base_mac or base_mac == '' then
        base_mac = board.network.lan and board.network.lan.macaddr
        wan_mac = base_mac
    end
    if not base_mac or base_mac == '' then
        return
    end

    for _, p in ipairs(ports or {}) do
        if tostring(p.support_wan or '0') == '1' then
            local sid = p.name:gsub('[^%w_-]', '_')
            local dm
            if p.wan_type == 'secondwan' then
                dm = secondwan_mac
            elseif p.wan_type == 'wan' then
                dm = wan_mac
            else
                dm = sfp_mac or mac_increase(base_mac, 3)
            end
            if dm then
                c:set('eth_ports_config_map', sid, 'default_mac', dm)
            end
        end
    end
end

-- ==================== map 初始化（gl-eth-ports.json → eth_ports_config_map） ====================

--- 功能：从机型端口 JSON 中解析并规范化端口列表。
--- JSON 结构：wan、sfp、lans（对象，lans 为 { lan1={...}, lan2={...} }）
--- @param eth_ports table 当前机型下的端口定义
--- @return table 端口列表，每项含 name/silk/support_wan/mode/port_group/type 等
local function collect_ports(eth_ports)
    local list = {}

    local function append_top(name, cfg)
        if name ~= 'lans' and type(cfg) == 'table' and cfg.port then
            list[#list + 1] = {
                name = name,
                port = cfg.port,
                silk = cfg.silk,
                support_wan = cfg.support_wan or '1',
                mode = cfg.mode or 'wan',
                port_group = tostring(cfg.port_group or '2'),
                type = cfg.type or 'dsa',
                cpu_port = cfg.cpu_port,
                switch = cfg.switch,
                main_interface = cfg.main_interface,
                wan_type = cfg.wan_type,
                wan_vlan = cfg.wan_vlan,
                default_vlan = cfg.default_vlan,
            }
        end
    end

    for _, name in ipairs(sorted_table_keys(eth_ports, function(a, b)
        if a == 'lans' then return false end
        if b == 'lans' then return true end
        return tostring(a) < tostring(b)
    end)) do
        append_top(name, eth_ports and eth_ports[name])
    end

    -- LAN 口：按 DSA/GSW 分组，DSA 一组，GSW 按 switch 号分组
    local pg = 3
    local seen_switch = {}
    if eth_ports.lans and type(eth_ports.lans) == 'table' then
        local function lan_key_cmp(a, b)
            local a_num = tostring(a):match('^lan(%d+)$')
            local b_num = tostring(b):match('^lan(%d+)$')
            if a_num and b_num then
                return tonumber(a_num) < tonumber(b_num)
            end
            if a_num then
                return false
            end
            if b_num then
                return true
            end
            return tostring(a) < tostring(b)
        end
        local function append_lan(lname, info)
            if type(info) == 'table' then
                local pgroup = tostring(pg)
                if info.type == 'gsw' and info.switch then
                    -- GSW：相同 switch 共用同一 port_group
                    if not seen_switch[info.switch] then
                        seen_switch[info.switch] = pgroup
                        pg = pg + 1
                    end
                    pgroup = seen_switch[info.switch]
                else
                    -- DSA：所有 DSA 口共用一组
                    if not seen_switch.dsa then
                        seen_switch.dsa = tostring(pg)
                        pg = pg + 1
                    end
                    pgroup = seen_switch.dsa
                end
                list[#list + 1] = {
                    name = lname,
                    port = info.port,
                    silk = info.silk,
                    support_wan = info.support_wan or '0',
                    mode = info.mode or 'lan',
                    port_group = tostring(info.port_group or pgroup),
                    type = info.type or 'dsa',
                    cpu_port = info.cpu_port,
                    switch = info.switch,
                    main_interface = info.main_interface,
                    wan_type = info.wan_type,
                    wan_vlan = info.wan_vlan,
                    default_vlan = info.default_vlan,
                }
            end
        end
        for _, lname in ipairs(sorted_table_keys(eth_ports.lans, lan_key_cmp)) do
            append_lan(lname, eth_ports.lans[lname])
        end
    end
    return list
end

--- 功能：将单个端口配置写入 eth_ports_config_map。
--- @param c table uci cursor
--- @param p table 标准化后的端口对象
--- @return nil
local function write_port(c, p)
    -- 节名需为合法 UCI 标识符（字母数字下划线）
    local sid = p.name:gsub('[^%w_-]', '_')
    c:set('eth_ports_config_map', sid, 'port')
    c:set('eth_ports_config_map', sid, 'name', p.name)
    if p.port ~= nil then
        c:set('eth_ports_config_map', sid, 'port', tostring(p.port))
    end
    c:set('eth_ports_config_map', sid, 'silk', p.silk)
    c:set('eth_ports_config_map', sid, 'support_wan', p.support_wan)
    c:set('eth_ports_config_map', sid, 'type', p.type or 'dsa')
    c:set('eth_ports_config_map', sid, 'port_group', p.port_group or '1')
    c:set('eth_ports_config_map', sid, 'default_mode', p.mode)
    c:set('eth_ports_config_map', sid, 'mode', p.mode)
    if p.wan_vlan ~= nil then
        c:set('eth_ports_config_map', sid, 'wan_vlan', tostring(p.wan_vlan))
    end
    -- wan_type：初始化时按 JSON 原样写入（仅 WAN 模式端口有效）
    if p.mode == 'wan' then
        if p.wan_type then
            c:set('eth_ports_config_map', sid, 'wan_type', p.wan_type)
        end
    end
    -- LAN 口默认：Standard 模式，统一 pvid=1（vlan1）。
    if p.mode == 'lan' then
        -- LAN 模式下不应保留 wan_type
        c:delete('eth_ports_config_map', sid, 'wan_type')
        c:set('eth_ports_config_map', sid, 'vlan_mode', 'access')
        c:set('eth_ports_config_map', sid, 'pvid', '1')
    end
    -- GSW 口额外字段
    if p.cpu_port then
        c:set('eth_ports_config_map', sid, 'cpu_port', p.cpu_port)
    end
    if p.switch then
        c:set('eth_ports_config_map', sid, 'switch', p.switch)
    end
    if p.main_interface then
        c:set('eth_ports_config_map', sid, 'main_interface', p.main_interface)
    end
    if p.default_vlan ~= nil then
        c:set('eth_ports_config_map', sid, 'default_vlan', tostring(p.default_vlan))
    end
end

--- 功能：写入 map 公共 section（如端口方向等全局字段）。
--- @param c table uci cursor
--- @param eth_ports table 原始端口 JSON 节点
--- @return nil
local function write_common_config(c, eth_ports)
    local sid = 'common'
    c:set('eth_ports_config_map', sid, 'common')
    if eth_ports and eth_ports.port_orientation ~= nil and tostring(eth_ports.port_orientation) ~= '' then
        c:set('eth_ports_config_map', sid, 'port_orientation', tostring(eth_ports.port_orientation))
    else
        c:delete('eth_ports_config_map', sid, 'port_orientation')
    end
end

--- 功能：清理历史 port/common section，为重建 map 做准备。
--- @param c table uci cursor
--- @return nil
local function clear_all_port_sections(c)
    local sids = {}
    if c.each then
        for s in c:each('eth_ports_config_map', 'port') do
            sids[#sids + 1] = s['.name']
        end
    elseif c.foreach then
        c:foreach('eth_ports_config_map', 'port', function(s)
            sids[#sids + 1] = s['.name']
        end)
    end
    for _, sid in ipairs(sids) do
        c:delete('eth_ports_config_map', sid)
    end
end

--- 功能：根据平台端口 JSON 全量初始化 eth_ports_config_map。
--- 初始化步骤：读取机型 -> 解析端口 -> 清空旧节 -> 写入新节 -> 提交。
--- @return number 0 表示成功，1 表示失败
function M.init_eth_ports_config_map()
    -- 1. 加载 gl-eth-ports.json（优先默认路径，否则尝试备用路径）
    local raw = readfile(ETH_PORTS_JSON)
    if not raw then
        for _, p in ipairs(ETH_PORTS_JSON_FALLBACKS) do
            raw = readfile(p)
            if raw then break end
        end
    end
    if not raw then
        return 1
    end
    local ok, port_map = pcall(cjson.decode, raw)
    if not ok or not port_map then
        return 1
    end

    -- 2. 读取当前机型（不存在则用 JSON 中第一个 model_id）
    local model = readfile(MODEL_FILE, '*l')
    if model then
        model = model:gsub('%s+', '')
    end
    if not model or model == '' then
        model = next(port_map)
    end
    if not model then
        return 1
    end

    -- 3. 按机型解析端口列表（结构：wan、sfp、lans）
    local eth_ports = port_map[model]
    if not eth_ports then
        return 1
    end
    local ports = collect_ports(eth_ports)
    if not ports or #ports == 0 then
        return 1
    end

    -- 4. 确保 /etc/config 存在（UCI 写入需要）
    local etc_config = '/etc/config'
    if not io.open(etc_config, 'r') then
        os.execute('mkdir -p ' .. etc_config .. ' 2>/dev/null')
    end

    -- 5. 逐个写入 UCI
    local c = uci.cursor()
    local ok_write = pcall(function()
        write_common_config(c, eth_ports)
        -- 先清除旧 port 节，避免重复 section（例如 sfp 被写入两次）
        clear_all_port_sections(c)
        for _, p in ipairs(ports) do
            write_port(c, p)
        end
        init_default_macs(c, ports)
    end)
    if not ok_write then
        if c then c:close() end
        return 1
    end
    -- LuCI UCI 需先 save 再 commit；原生 uci 的 save 可能为 no-op
    if c.save then
        c:save('eth_ports_config_map')
    end
    local ok_commit = c:commit('eth_ports_config_map')
    c:close()
    if not ok_commit then
        return 1
    end
    return 0
end

-- ==================== map 读取（eth_ports_config_map → PortConfig 表） ====================

--- 功能：按稳定顺序遍历 map 中所有 port section。
--- @param c table uci cursor
--- @param fn function 回调函数，参数为 section table
--- @return boolean, any 成功标志与错误对象
local function iterate_port_sections(c, fn)
    if c.each then
        local ok, err = pcall(function()
            for s in c:each('eth_ports_config_map', 'port') do
                fn(s)
            end
        end)
        return ok, err
    end
    if c.foreach then
        local ok, err = pcall(function()
            c:foreach('eth_ports_config_map', 'port', function(s)
                fn(s)
            end)
        end)
        return ok, err
    end
    return false, 'UCI cursor has neither each nor foreach'
end

--- 功能：安全地将值转换为数字。
--- @param v any 待转换值
--- @param default number 转换失败时返回的默认值
--- @return number 转换结果或默认值
local function to_number_safe(v, default)
    local n = tonumber(v)
    if n == nil then
        return default
    end
    return n
end

--- 功能：读取并解析 tagged_vlans，兼容 list 与字符串存储格式。
--- @param c table uci cursor
--- @param sid string 端口 section id
--- @return table 整型 VLAN 列表（非法值自动过滤）
local function read_tagged_vlans(c, sid)
    local trunk_tag = {}
    local list = nil

    if c.get_list then
        list = c:get_list('eth_ports_config_map', sid, 'tagged_vlans')
    end

    -- 兼容部分环境：tagged_vlans 可能以字符串形态存在（如 "20 30 40" 或 "20,30,40"）。
    if (not list or #list == 0) and c.get then
        local raw = c:get('eth_ports_config_map', sid, 'tagged_vlans')
        if type(raw) == 'string' and raw ~= '' then
            list = {}
            for token in raw:gmatch('[^,%s]+') do
                list[#list + 1] = token
            end
        end
    end

    if list then
        for _, v in ipairs(list) do
            local n = to_number_safe(v, 0)
            if n > 0 then
                trunk_tag[#trunk_tag + 1] = n
            end
        end
    end

    return trunk_tag
end

--- 功能：将 UCI 端口 section 转换为业务侧端口配置对象。
--- @param c table uci cursor
--- @param sid string section id
--- @return table|nil 端口对象；缺少 name 时返回 nil
local function build_port_config_from_section(c, sid)
    local name = c:get('eth_ports_config_map', sid, 'name')
    if not name then
        return nil
    end

    local mode = c:get('eth_ports_config_map', sid, 'mode') or 'lan'
    local vlan_mode = c:get('eth_ports_config_map', sid, 'vlan_mode') or 'access'
    local pvid = to_number_safe(select(1, c:get('eth_ports_config_map', sid, 'pvid')), 1)
    local trunk_tag = read_tagged_vlans(c, sid)

    return {
        name = name,
        mode = mode,
        vlan_mode = vlan_mode,
        pvid = pvid,
        trunk_tag = trunk_tag,
        type = c:get('eth_ports_config_map', sid, 'type') or 'dsa',
        port = c:get('eth_ports_config_map', sid, 'port'),
        switch = c:get('eth_ports_config_map', sid, 'switch'),
        cpu_port = c:get('eth_ports_config_map', sid, 'cpu_port'),
        main_interface = c:get('eth_ports_config_map', sid, 'main_interface'),
        silk = c:get('eth_ports_config_map', sid, 'silk'),
        support_wan = c:get('eth_ports_config_map', sid, 'support_wan') or '0',
        port_group = c:get('eth_ports_config_map', sid, 'port_group') or '1',
        default_mode = c:get('eth_ports_config_map', sid, 'default_mode') or mode,
        wan_type = c:get('eth_ports_config_map', sid, 'wan_type'),
        wan_vlan = c:get('eth_ports_config_map', sid, 'wan_vlan'),
        default_vlan = c:get('eth_ports_config_map', sid, 'default_vlan'),
        default_mac = c:get('eth_ports_config_map', sid, 'default_mac'),
    }
end

--- 功能：加载 map 中全部端口配置，并按端口名建立索引。
--- @return table name -> config 映射
function M.load_ports_config_from_map()
    local c = uci.cursor()
    local all = {}
    local ok, err = iterate_port_sections(c, function(s)
            local item = build_port_config_from_section(c, s['.name'])
            if item then
                all[item.name] = item
            end
    end)
    c:close()
    if not ok then
        io.stderr:write('libcable.load_ports_config_from_map error: ' .. tostring(err) .. '\n')
    end
    return all
end

--- 功能：按逻辑端口名读取单个端口配置。
--- 兼容逻辑别名：当 name=wan/secondwan 时，会通过 wan_type 反查真实端口。
--- @param name string 逻辑端口名
--- @return table|nil 命中的端口配置
function M.get_port_config_from_map(name)
    local c = uci.cursor()
    local out = nil
    local by_wan_type = nil
    local ok, err = iterate_port_sections(c, function(s)
            if out then
                return
            end
            local item = build_port_config_from_section(c, s['.name'])
            if item and item.name == name then
                out = item
            elseif item and (name == 'wan' or name == 'secondwan') and item.wan_type == name then
                -- 兼容上层仅传逻辑名 wan/secondwan 的场景：
                -- 通过 wan_type 反查真实端口；优先命中 mode=wan 的口。
                if item.mode == 'wan' then
                    out = item
                elseif not by_wan_type then
                    by_wan_type = item
                end
            end
    end)
    if not out then
        out = by_wan_type
    end
    c:close()
    if not ok then
        io.stderr:write('libcable.get_port_config_from_map error: ' .. tostring(err) .. '\n')
    end
    return out
end

--- 功能：以稳定顺序导出端口列表，供 RPC 层直接返回。
--- @return table 端口数组
function M.get_ports_list_from_map()
    local c = uci.cursor()
    local list = {}
    local idx_by_name = {}
    local ok, err = iterate_port_sections(c, function(s)
            local item = build_port_config_from_section(c, s['.name'])
            if item then
                if item.mode == 'lan' and item.type == 'gsw' and tonumber(item.pvid) and tonumber(item.pvid) > 4000 then
                    item.pvid = 1
                end
                local name = item.name
                -- 同名端口去重：保留最后一次，避免历史脏配置导致重复输出
                if idx_by_name[name] then
                    list[idx_by_name[name]] = item
                else
                    list[#list + 1] = item
                    idx_by_name[name] = #list
                end
            end
    end)
    c:close()
    if not ok then
        io.stderr:write('libcable.get_ports_list_from_map error: ' .. tostring(err) .. '\n')
    end
    return list
end

function M.get_switchable_port_count()
    local all = M.load_ports_config_from_map()
    return count_switchable_ports(all)
end

--- 功能：在切换到 WAN 时计算目标 wan_type（wan/secondwan）。
--- 策略：根据可切 WAN 数量、现有占位与端口类型（DSA/GSW）综合决定。
--- @param name string 目标端口名
--- @param new_mode string 目标模式
--- @return string|nil 计算出的 wan_type，非 WAN 场景返回 nil
function M.compute_wan_type_on_mode_switch(name, new_mode)
    if new_mode ~= 'wan' then
        return nil
    end
    local all = M.load_ports_config_from_map()
    local p = all[name]
    if not p then return nil end
    local switchable_cnt = count_switchable_ports(all)
    if switchable_cnt == 1 then
        return 'wan'
    end
    if switchable_cnt == 2 then
        -- 不通过 name 决策，依据当前 WAN 占位状态分配。
        -- 若其它 WAN 口已是主 WAN，则本口为 secondwan；否则本口为 wan。
        local has_wan = false
        for n, cfg in pairs(all) do
            if n ~= name and cfg.mode == 'wan' and cfg.wan_type == 'wan' then
                has_wan = true
                break
            end
        end
        return has_wan and 'secondwan' or 'wan'
    end
--    if tostring(p.default_mode or '') ~= 'wan' then
--        return 'secondwan'
--    end
    -- wan/sfp：检查剩余 WAN 口中是否已有 wan_type=wan
    local has_wan = false
    for n, cfg in pairs(all) do
        if n ~= name and cfg.mode == 'wan' and cfg.wan_type == 'wan' then
            has_wan = true
            break
        end
    end
    return has_wan and 'secondwan' or 'wan'
end

-- ==================== map→network 下发（eth_ports_config_map → network，DSA/GSW） ====================

--- 功能：将空白分隔字符串拆分为 token 数组。
--- @param s string|nil 原始字符串
--- @return table token 数组
local function split_ws(s)
    local out = {}
    if not s or s == '' then return out end
    for x in tostring(s):gmatch('%S+') do
        out[#out + 1] = x
    end
    return out
end

--- 功能：判断列表是否包含指定值。
--- @param list table|nil 列表
--- @param val any 目标值
--- @return boolean 是否包含
local function list_contains(list, val)
    for _, x in ipairs(list or {}) do
        if x == val then
            return true
        end
    end
    return false
end

--- 功能：按谓词过滤列表，返回移除命中项后的新列表。
--- @param list table|nil 原列表
--- @param fn function 谓词函数，返回 true 的元素将被移除
--- @return table 过滤后的新列表
local function list_remove_if(list, fn)
    local out = {}
    for _, x in ipairs(list or {}) do
        if not fn(x) then
            out[#out + 1] = x
        end
    end
    return out
end

--- 功能：仅在值不存在时追加到列表末尾。
--- @param list table 目标列表
--- @param val any 待追加值
--- @return nil
local function list_add_unique(list, val)
    if not list_contains(list, val) then
        list[#list + 1] = val
    end
end

--- 功能：以 set_list/add_list 兼容方式写入 UCI list 选项。
--- @param c table uci cursor
--- @param conf string 配置文件名（如 network）
--- @param sid string section id
--- @param opt string 选项名
--- @param values table|nil 待写入列表
--- @return nil
local function set_opt_list(c, conf, sid, opt, values)
    c:delete(conf, sid, opt)
    if not values or #values == 0 then
        return
    end
    if c.set_list then
        c:set_list(conf, sid, opt, values)
        return
    end
    if c.add_list then
        for _, v in ipairs(values) do
            c:add_list(conf, sid, opt, tostring(v))
        end
        return
    end
    -- 传入 table 而非字符串：OpenWrt libuci Lua 绑定的 c:set() 对 table 值会写成 list 格式。
    c:set(conf, sid, opt, values)
end

--- 功能：以 option 方式写入 switch_vlan ports（空格分隔字符串）。
--- @param c table uci cursor
--- @param sid string section id
--- @param values table|nil 端口列表
--- @return nil
local function set_switch_vlan_ports(c, sid, values)
    if not values or #values == 0 then
        c:delete('network', sid, 'ports')
        return
    end
    c:set('network', sid, 'ports', table.concat(values, ' '))
end

--- 功能：通过设备名定位 network.device section id。
--- @param c table uci cursor
--- @param dev_name string 设备名
--- @return string|nil section id
local function find_device_sid_by_name(c, dev_name)
    for s in c:each('network', 'device') do
        if s.name == dev_name then
            return s['.name']
        end
    end
    return nil
end

--- 功能：分配可用的 device section id。
--- @param c table uci cursor
--- @param fallback_sid string 回退 section id
--- @return string 可用 section id
local function alloc_device_sid(c, fallback_sid)
    if c.add then
        local sid = c:add('network', 'device')
        if sid then
            return sid
        end
    end
    return fallback_sid
end

--- 功能：确保 swconfig VLAN 对应的 device section 存在且字段正确。
--- @param c table uci cursor
--- @param dev_name string 目标设备名（如 eth1.20）
--- @param ifname string 基础 ifname（如 eth1）
--- @param vid number VLAN ID
--- @return nil
local function ensure_gsw_device(c, dev_name, ifname, vid)
    local sid = find_device_sid_by_name(c, dev_name)
    if not sid then
        sid = alloc_device_sid(c, ('map_dev_%s_%s'):format(tostring(ifname):gsub('[^%w_]', '_'), tostring(vid)))
    end
    c:set('network', sid, 'device')
    c:set('network', sid, 'name', dev_name)
    c:set('network', sid, 'ifname', ifname)
end

--- 功能：读取 LAN bridge 成员端口，并兼容 device/ifname 两种 schema。
--- @param c table uci cursor
--- @return table, string|nil, boolean, string|nil ports, lan_dev_name, use_device, lan_dev_sid
local function get_lan_ports(c)
    local lan_device = c:get('network', 'lan', 'device')
    if lan_device then
        local sid = find_device_sid_by_name(c, lan_device)
        if sid then
            local s = c:get_all('network', sid) or {}
            if type(s.ports) == 'table' then
                return s.ports, lan_device, true, sid
            end
            return split_ws(s.ports), lan_device, true, sid
        end
        return {}, lan_device, true, nil
    end
    local ifname = c:get('network', 'lan', 'ifname')
    return split_ws(ifname), nil, false, nil
end

--- 功能：在 device/ifname 两种 schema 下保存 LAN bridge 端口列表。
--- @param c table uci cursor
--- @param ports table 目标成员端口数组
--- @param lan_dev_name string|nil LAN bridge 设备名
--- @param use_device boolean 是否使用 device schema
--- @param lan_dev_sid string|nil LAN device section id
--- @return nil
local function save_lan_ports(c, ports, lan_dev_name, use_device, lan_dev_sid)
    if use_device then
        local sid = lan_dev_sid or find_device_sid_by_name(c, lan_dev_name)
        if not sid then
            sid = alloc_device_sid(c, 'lan_dev')
            c:set('network', sid, 'device')
            c:set('network', sid, 'name', lan_dev_name)
            c:set('network', sid, 'type', 'bridge')
        end
        set_opt_list(c, 'network', sid, 'ports', ports)
        return
    end
    c:set('network', 'lan', 'ifname', table.concat(ports, ' '))
end

--- 功能：从端口列表中移除基础端口及其 VLAN 子接口。
--- @param ports table 端口列表
--- @param base_port string 基础端口名（如 eth1）
--- @return table 过滤后的端口列表
local function strip_port_and_subifs(ports, base_port)
    local prefix = tostring(base_port) .. '.'
    return list_remove_if(ports, function(x)
        return x == base_port or tostring(x):sub(1, #prefix) == prefix
    end)
end

--- 功能：删除包含目标端口的 switch_vlan section（保留白名单除外）。
--- @param c table uci cursor
--- @param switch_dev string|nil 交换机设备名
--- @param port_num string|number 目标端口号
--- @param keep_sids table|nil 保留 sid 集合（键为 sid，值为 true）
--- @param cpu_port string|number|nil CPU 口
--- @return nil
local function remove_switch_vlans_for_port(c, switch_dev, port_num, keep_sids, cpu_port)
    local p = tostring(port_num)
    local cpu_norm = tostring(cpu_port or '0t'):gsub('t$', '')
    local function is_cpu_only_ports(ports)
        if not ports or #ports == 0 then
            return true
        end
        for _, x in ipairs(ports) do
            if tostring(x):gsub('t$', '') ~= cpu_norm then
                return false
            end
        end
        return true
    end

    for s in c:each('network', 'switch_vlan') do
        if switch_dev == nil or s.device == switch_dev then
            local sid = s['.name']
            if not (keep_sids and keep_sids[sid]) then
                -- 只移除目标端口相关成员，其他端口保持不动。
                local entries = type(s.ports) == 'table' and s.ports or split_ws(s.ports)
                local filtered = {}
                local removed = false
                for _, x in ipairs(entries) do
                    if tostring(x):match('^' .. p .. '[ut]?$') then
                        removed = true
                    else
                        filtered[#filtered + 1] = x
                    end
                end

                if removed then
                    if is_cpu_only_ports(filtered) then
                        local v = tonumber(s.vlan)
                        -- 4xxx 内部 VLAN 需要保留；
                        -- 普通 VLAN 若只剩 CPU 口则直接删除，减少冗余。
                        if v and v > 4000 then
                            set_switch_vlan_ports(c, sid, filtered)
                        else
                            c:delete('network', sid)
                        end
                    else
                        set_switch_vlan_ports(c, sid, filtered)
                    end
                end
            end
        end
    end
end

--- 功能：写入并规范化单个 switch_vlan section。
--- @param c table uci cursor
--- @param sid string|nil 目标 section id，为 nil 时自动分配
--- @param switch_dev string 交换机设备名
--- @param vlan_id number VLAN ID
--- @param ports table 端口成员列表
--- @return string section id
local function write_switch_vlan(c, sid, switch_dev, vlan_id, ports)
    local section = sid
    if not section and c.add then
        section = c:add('network', 'switch_vlan')
    end
    if not section then
        section = ('map_switch_vlan_%s_%s'):format(tostring(switch_dev or 'switch'), tostring(vlan_id))
    end
    c:set('network', section, 'switch_vlan')
    c:set('network', section, 'device', switch_dev)
    c:set('network', section, 'vlan', tostring(vlan_id))
    set_switch_vlan_ports(c, section, ports)
    return section
end

--- 功能：将 network.device 的 ports 统一读取为数组格式。
--- @param c table uci cursor
--- @param dev_sid string device section id
--- @return table ports 数组
local function read_device_ports(c, dev_sid)
    local s = c:get_all('network', dev_sid) or {}
    if type(s.ports) == 'table' then
        return s.ports
    end
    return split_ws(s.ports)
end

--- 功能：确保 DSA VLAN 子接口 device section 存在且字段正确。
--- @param c table uci cursor
--- @param base string 基础端口名（如 eth0）
--- @param vid number VLAN ID
--- @return string 生成的 device 名（如 eth0.20）
local function ensure_dsa_vlan_device(c, base, vid)
    local dev_name = tostring(base) .. '.' .. tostring(vid)
    local sid = find_device_sid_by_name(c, dev_name)
    if not sid then
        sid = alloc_device_sid(c, ('map_dsa_dev_%s_%s'):format(tostring(base):gsub('[^%w_]', '_'), tostring(vid)))
    end
    -- DSA VLAN 子接口按需求写为 name/ifname 形态。
    c:set('network', sid, 'device')
    c:set('network', sid, 'name', dev_name)
    c:set('network', sid, 'ifname', tostring(base))
    return dev_name
end

--- 功能：根据 VLAN ID 识别是否对应固定子网桥（br-guest / br-iot）。
--- 直接从 UCI 读取 network.<guest|iot>.vlan_id，无需依赖 /tmp/vlan_port_map。
--- @param vid number|string VLAN ID
--- @return string|nil bridge device name（命中时返回 br-guest 或 br-iot）
local function get_fixed_bridge_name_by_vid(vid)
    local v = tonumber(vid)
    if not v or v <= 0 then
        return nil
    end
    local c = uci.cursor()
    for _, net in ipairs({'guest', 'iot'}) do
        local net_vid = tonumber(c:get('network', net, 'vlan_id'))
        if net_vid == v then
            c:close()
            return 'br-' .. net
        end
    end
    c:close()
    return nil
end

--- 功能：将 bridge 设备名转换为 VLAN ID（用于端口旧状态识别）。
--- @param dev_name string bridge 设备名
--- @return number|nil VLAN ID
local function get_bridge_vid_by_name(dev_name)
    if dev_name == 'br-lan' then
        return 1
    end
    local vid = tonumber(tostring(dev_name):match('^br%-vlan(%d+)$'))
    if vid then
        return vid
    end
    if dev_name == 'br-guest' or dev_name == 'br-iot' then
        local net = dev_name:match('^br%-(.+)$')
        local c = uci.cursor()
        local v = tonumber(c:get('network', net, 'vlan_id'))
        c:close()
        return v
    end
    return nil
end

local function ensure_bridge_sid_for_vid(c, vid)
    local v = tonumber(vid)
    if v == 1 or (v and v > 4000 and v ~= 4002 and v ~= 4003) then
        local sid = find_device_sid_by_name(c, 'br-lan')
        if sid then
            return sid
        end
    end
    local fixed_bridge_name = get_fixed_bridge_name_by_vid(v or vid)
    if fixed_bridge_name then
        local sid = find_device_sid_by_name(c, fixed_bridge_name)
        if sid then
            return sid
        end
    end
    return find_device_sid_by_name(c, 'br-vlan' .. tostring(v or vid))
end

--- 功能：由 bridge 名推导对应 interface 名（固定映射）。
--- @param bridge_name string
--- @return string|nil
local function interface_name_by_bridge(bridge_name)
    if bridge_name == 'br-lan' then return 'lan' end
    if bridge_name == 'br-guest' then return 'guest' end
    if bridge_name == 'br-iot' then return 'iot' end
    local vid = tostring(bridge_name):match('^br%-vlan(%d+)$')
    if vid then
        return 'vlan' .. vid
    end
    return nil
end

--- 当 guest/iot 桥对应 WiFi 全部关闭时，自动 disable 该 interface。
local function disable_guest_iot_if_wifi_off(c, br_name)
    local prefix
    if br_name == 'br-guest' then
        prefix = 'guest'
    elseif br_name == 'br-iot' then
        prefix = 'iot'
    else
        return
    end
    local iface = interface_name_by_bridge(br_name)
    if not iface or not c:get('network', iface) then
        return
    end
    for _, band in ipairs({'2g', '5g', '6g'}) do
        if c:get('wireless', prefix .. band, 'disabled') == '0' then
            return  -- 仍有 WiFi 开启
        end
    end
    c:set('network', iface, 'disabled', '1')
end

--- 功能：从全部 VLAN bridge 中移除指定基础端口及其子接口成员。
--- @param c table uci cursor
--- @param base string 基础端口名
--- @return nil
local function remove_port_from_all_vlan_bridges(c, base)
    local esc = tostring(base):gsub('([%.%-%+%*%?%[%]%^%$%(%)%%])', '%%%1')
    for s in c:each('network', 'device') do
        local name = tostring(s.name or '')
        if name:match('^br%-vlan%d+$') or name == 'br-lan' or name == 'br-guest' or name == 'br-iot' then
            local sid = s['.name']
            local ports = read_device_ports(c, sid)
            local filtered = list_remove_if(ports, function(x)
                local p = tostring(x)
                if p:match('^' .. esc .. '%.400[23]$') then return false end
                return p == base or p:match('^' .. esc .. '%.%d+$') ~= nil
            end)
            set_opt_list(c, 'network', sid, 'ports', filtered)
        end
    end
end

--- 功能：确保 GSW bridge 成员与目标 VLAN 集合保持一致。
--- @param c table uci cursor
--- @param main_if string 主接口名
--- @param vids table 目标 VLAN 集合（键为 VLAN ID，值为 true）
--- @return nil
local function ensure_gsw_bridge_members(c, main_if, vids)
    if not main_if or main_if == '' then
        return
    end
    for vid in pairs(vids or {}) do
        local v = tonumber(vid)
        if v and v > 0 then
            local dev_name = tostring(main_if) .. '.' .. tostring(v)
            ensure_gsw_device(c, dev_name, tostring(main_if), v)
            local br_sid = ensure_bridge_sid_for_vid(c, v)
            if br_sid then
                local ports = read_device_ports(c, br_sid)
                local old_cnt = #ports
                list_add_unique(ports, dev_name)
                set_opt_list(c, 'network', br_sid, 'ports', ports)
                if #ports ~= old_cnt then
                    local br_name = c:get('network', br_sid, 'name')
                    local iface = interface_name_by_bridge(br_name)
                    if iface and c:get('network', iface) and c:get('network', iface, 'disabled') == '1' then
                        c:set('network', iface, 'disabled', '0')
                    end
                end
            end
        end
    end
end

--- 功能：根据 switch_vlan 配置重建 GSW bridge 成员关系。
--- @param c table uci cursor
--- @param cfg table 端口配置（包含 switch/cpu_port/main_interface）
--- @return nil
local function sync_gsw_bridge_members_from_switch(c, cfg)
    local main_if = tostring(cfg.main_interface or '')
    if main_if == '' then
        return
    end

    -- 先清空再重建，保证多次执行结果一致（幂等）。
    remove_port_from_all_vlan_bridges(c, main_if)

    local sw = cfg.switch
    local cpu_norm = tostring(cfg.cpu_port or '0t'):gsub('t$', '')
    local vids = {}
    for s in c:each('network', 'switch_vlan') do
        if sw == nil or s.device == sw then
            local vid = tonumber(s.vlan)
            if vid and vid > 0 and vid ~= 4095 then
                local entries = type(s.ports) == 'table' and s.ports or split_ws(s.ports)
                local has_non_cpu = false
                for _, x in ipairs(entries or {}) do
                    if tostring(x):gsub('t$', '') ~= cpu_norm then
                        has_non_cpu = true
                        break
                    end
                end
                if has_non_cpu then
                    -- 只有包含业务端口（非纯 CPU）的 VLAN，才加入 bridge 映射。
                    vids[vid] = true
                end
            end
        end
    end

    ensure_gsw_bridge_members(c, main_if, vids)

    -- 清理不再被任何 switch_vlan 引用的 GSW 子接口 device section（如 eth1.30），
    -- 避免 switch_vlan 删除后对应 device section 残留成孤立配置。
    -- keep_devs 记录仍在使用的子接口名，不在其中的一律删除。
    local keep_devs = {}
    for vid in pairs(vids) do
        keep_devs[main_if .. '.' .. tostring(vid)] = true
    end
    local esc_if = main_if:gsub('([%.%-%+%*%?%[%]%^%$%(%)%%])', '%%%1')
    for s in c:each('network', 'device') do
        local dev_name = tostring(s.name or '')
        if dev_name:match('^' .. esc_if .. '%.%d+$') and not keep_devs[dev_name] then
            c:delete('network', s['.name'])
        end
    end

    -- 所有清理完成后，guest/iot 桥内无端口时 disable。
    for s in c:each('network', 'device') do
        local br_name = tostring(s.name or '')
        if br_name == 'br-guest' or br_name == 'br-iot' then
            if #read_device_ports(c, s['.name']) == 0 then
                disable_guest_iot_if_wifi_off(c, br_name)
            end
        end
    end
end

--- 功能：清理未被引用的 DSA 子接口 device section。
--- @param c table uci cursor
--- @param base string 基础端口名
--- @param keep_subifs table 保留子接口集合（键为设备名，值为 true）
--- @return nil
local function cleanup_unused_dsa_subifs(c, base, keep_subifs)
    local esc = tostring(base):gsub('([%.%-%+%*%?%[%]%^%$%(%)%%])', '%%%1')
    for s in c:each('network', 'device') do
        local name = tostring(s.name or '')
        if name:match('^' .. esc .. '%.%d+$') and not keep_subifs[name] then
            c:delete('network', s['.name'])
        end
    end
end

--- 功能：当端口处于 LAN 模式时清理其 wan_type 字段。
--- @param name string 端口名
--- @return nil
local function clear_wan_type_by_name_if_lan(name)
    if not name or name == '' then
        return
    end
    local m = uci.cursor()
    local sid = nil
    for s in m:each('eth_ports_config_map', 'port') do
        if m:get('eth_ports_config_map', s['.name'], 'name') == name then
            sid = s['.name']
            break
        end
    end
    if sid and m:get('eth_ports_config_map', sid, 'mode') == 'lan' and m:get('eth_ports_config_map', sid, 'wan_type') then
        m:delete('eth_ports_config_map', sid, 'wan_type')
        m:commit('eth_ports_config_map')
    end
    m:close()
end

--- 功能：将单个 DSA LAN 配置下发到 network。
--- 处理内容：
--- 1) 比较新旧 PVID，决定是否迁移 untag 端口成员；
--- 2) 比较新旧 Tag VLAN 集合，决定哪些子接口需要新增、哪些需要删除；
--- 3) 同步 bridge 成员与 DSA 子接口，确保配置与目标状态一致。
--- @param c table uci cursor
--- @param cfg table 端口配置（mode/vlan_mode/pvid/trunk_tag/port）
--- @param name string 端口名（用于清理 wan_type）
--- @return nil
local function apply_dsa_lan(c, cfg, name)
    clear_wan_type_by_name_if_lan(name)
    local base = tostring(cfg.port or '')
    if base == '' then return end

    local new_pvid = tonumber(cfg.pvid) or 1
    local new_tags = {}          -- [vid] = true（目标 tagged VLAN）
    if cfg.vlan_mode == 'trunk' then
        for _, vid in ipairs(cfg.trunk_tag or {}) do
            local v = tonumber(vid)
            if v and v > 0 then
                if v ~= new_pvid then
                    new_tags[v] = true
                end
            end
        end
    end

    local old_pvid = nil
    local old_tags = {}          -- [tvid] = bridge_vid（旧 tagged VLAN → 所在 bridge 的 bridge_sections 键）
    local bridge_sections = {}   -- [vid] = { sid, ports }（仅记录已存在 bridge）
    local esc_base = base:gsub('([%.%-%+%*%?%[%]%^%$%(%)%%])', '%%%1')

    -- 先读取旧状态快照：
    -- - old_pvid：旧 untag VLAN
    -- - old_tags：旧 tagged VLAN 集合
    -- 后续只改“发生变化”的部分，避免每次都全量重写。
    for s in c:each('network', 'device') do
        local dev_name = tostring(s.name or '')
        local vid = get_bridge_vid_by_name(dev_name)
        if vid then
            local sid = s['.name']
            local ports = read_device_ports(c, sid)
            bridge_sections[vid] = { sid = sid, ports = ports }
            for _, x in ipairs(ports) do
                local p = tostring(x)
                if p == base then
                    old_pvid = vid
                elseif p:match('^' .. esc_base .. '%.(%d+)$') then
                    local tvid = tonumber(p:match('^' .. esc_base .. '%.(%d+)$'))
                    if tvid then
                        old_tags[tvid] = vid
                    end
                end
            end
        end
    end

    local function save_bridge_ports(vid, ports)
        local info = bridge_sections[vid]
        if not info then
            return
        end
        -- 按需求：不删除 bridge，仅更新 ports（为空时清空 ports 选项）。
        set_opt_list(c, 'network', info.sid, 'ports', ports or {})
        info.ports = ports or {}
        -- 桥内端口为空时，将对应 interface 设为 disabled
        if not ports or #ports == 0 then
            disable_guest_iot_if_wifi_off(c, c:get('network', info.sid, 'name'))
        end
    end

    local function remove_entry_from_bridge(vid, matcher)
        local info = bridge_sections[vid]
        if not info then
            return
        end
        local filtered = {}
        local removed = false
        for _, x in ipairs(info.ports or {}) do
            local p = tostring(x)
            if matcher(p) then
                removed = true
            else
                filtered[#filtered + 1] = p
            end
        end
        if removed then
            save_bridge_ports(vid, filtered)
        end
    end

    local function ensure_entry_on_bridge(vid, entry)
        local info = bridge_sections[vid]
        if not info then
            -- 按需求：不新增 bridge；目标 bridge 不存在时跳过。
            return
        end
        local ports = info.ports or {}
        local old_cnt = #ports
        list_add_unique(ports, entry)
        if #ports ~= old_cnt then
            save_bridge_ports(vid, ports)
            local br_name = c:get('network', info.sid, 'name')
            local iface = interface_name_by_bridge(br_name)
            if iface and c:get('network', iface) and c:get('network', iface, 'disabled') == '1' then
                c:set('network', iface, 'disabled', '0')
            end
        end
    end

    -- 先确保目标 tag 需要的子接口 device 存在（已有则复用）。
    for vid in pairs(new_tags) do
        ensure_dsa_vlan_device(c, base, vid)
    end

    -- pvid 变化时：先从旧 bridge 移除，再加入新 bridge。
    -- pvid 不变时：仍确保目标成员存在。
    if old_pvid and old_pvid ~= new_pvid then
        remove_entry_from_bridge(old_pvid, function(p)
            return p == base
        end)
    end
    -- trunk+pvid=0 时不配 PVID（不加入任何 bridge），untag 包丢弃。
    if cfg.vlan_mode ~= 'trunk' or new_pvid ~= 0 then
        ensure_entry_on_bridge(new_pvid, base)
    end

    -- Tag VLAN 变更分两类处理：
    -- 1) 旧配置里有、但新配置里没有的 VLAN：
    --    需要把对应的 tag 成员从 bridge 移除，并删除对应子接口设备。
    -- 2) 新配置里有、但旧配置里没有的 VLAN：
    --    需要把对应的 tag 成员补进 bridge，并确保目标子接口可用。
    for tvid, bridge_vid in pairs(old_tags) do
        if not new_tags[tvid] and tvid ~= 4002 and tvid ~= 4003 then
            local tag_dev = base .. '.' .. tostring(tvid)
            remove_entry_from_bridge(bridge_vid, function(p)
                return p == tag_dev
            end)
            local tag_sid = find_device_sid_by_name(c, tag_dev)
            if tag_sid then
                c:delete('network', tag_sid)
            end
        end
    end
    for vid in pairs(new_tags) do
        if not old_tags[vid] then  -- old_tags[vid] 非 nil 表示该 tag 已存在
            ensure_entry_on_bridge(vid, base .. '.' .. tostring(vid))
        end
    end
end

--- 功能：将单个 DSA WAN 配置下发到 network。
--- @param c table uci cursor
--- @param cfg table 端口配置（至少包含 port）
--- @return nil
local function apply_dsa_wan(c, cfg)
    local base = tostring(cfg.port or '')
    if base == '' then
        return
    end

    local ports, lan_dev_name, use_device, lan_dev_sid = get_lan_ports(c)
    local filtered = strip_port_and_subifs(ports, base)
    save_lan_ports(c, filtered, lan_dev_name, use_device, lan_dev_sid)

    remove_port_from_all_vlan_bridges(c, base)

    cleanup_unused_dsa_subifs(c, base, {})
end

--- 功能：将单个 GSW LAN 配置下发到 network。
--- 处理内容：
--- 1) 比较新旧 PVID 与 Tag 集合，确定 switch_vlan 的增删改；
--- 2) 对变更 VLAN 执行“移除旧成员 / 补齐新成员”；
--- 3) 最后按 switch_vlan 结果同步 bridge 成员，确保转发路径一致。
--- @param c table uci cursor
--- @param cfg table 端口配置（switch/port/cpu_port/pvid/vlan_mode/trunk_tag）
--- @param name string 端口名（用于清理 wan_type）
--- @return nil
local function apply_gsw_lan(c, cfg, name)
    clear_wan_type_by_name_if_lan(name)
    local function is_cpu_only_ports(ports, cpu_port)
        if not ports or #ports == 0 then
            return true
        end
        local cpu_norm = tostring(cpu_port or '0t'):gsub('t$', '')
        for _, x in ipairs(ports) do
            if tostring(x):gsub('t$', '') ~= cpu_norm then
                return false
            end
        end
        return true
    end

    local sw = cfg.switch
    local p = tostring(cfg.port or '')
    local cpu = cfg.cpu_port or '0t'
    if p == '' then return end

    local new_pvid = tonumber(cfg.pvid) or 1
    local new_tags = {}
    if cfg.vlan_mode == 'trunk' then
        for _, vid in ipairs(cfg.trunk_tag or {}) do
            local x = tonumber(vid)
            if x and x > 0 then
                if x ~= new_pvid then
                    new_tags[x] = true
                end
                if cfg.main_interface then
                    ensure_gsw_device(c, cfg.main_interface .. '.' .. tostring(x), cfg.main_interface, x)
                end
            end
        end
    end

    local old_pvid = nil
    local old_tags = {}
    local vlan_sections = {}
    -- 先建立 switch_vlan 快照，后面只改真正变化的 VLAN 项，
    -- 这样可以减少无意义改动，降低配置抖动风险。
    for s in c:each('network', 'switch_vlan') do
        if sw == nil or s.device == sw then
            local vlan_id = tonumber(s.vlan)
            local entries = type(s.ports) == 'table' and s.ports or split_ws(s.ports)
            if vlan_id then
                vlan_sections[vlan_id] = { sid = s['.name'], ports = entries }
                for _, x in ipairs(entries) do
                    local v = tostring(x)
                    if v:match('^' .. p .. 'u?$') then
                        old_pvid = vlan_id
                    elseif v == p .. 't' then
                        old_tags[vlan_id] = true
                    end
                end
            end
        end
    end

    local function save_ports_or_delete_if_cpu_only(vid, ports)
        local info = vlan_sections[vid]
        if not info then
            return
        end
        if is_cpu_only_ports(ports, cpu) then
            -- 4xxx 内部 VLAN 要保留；普通 VLAN 仅剩 CPU 口时删除。
            -- 4095 是 trunk+pvid=0 的伪 native VLAN，允许自动清理。
            if tonumber(vid) and tonumber(vid) > 4000 and vid ~= 4095 then
                set_switch_vlan_ports(c, info.sid, ports)
                info.ports = ports
            else
                c:delete('network', info.sid)
                vlan_sections[vid] = nil
            end
        else
            set_switch_vlan_ports(c, info.sid, ports)
            info.ports = ports
        end
    end

    local function remove_entry_from_vlan(vid, matcher)
        local info = vlan_sections[vid]
        if not info then
            return
        end
        local ports = info.ports or {}
        local filtered = {}
        local removed = false
        for _, x in ipairs(ports) do
            local v = tostring(x)
            if matcher(v) then
                removed = true
            else
                filtered[#filtered + 1] = x
            end
        end
        if removed then
            save_ports_or_delete_if_cpu_only(vid, filtered)
        end
    end

    local function ensure_entry_on_vlan(vid, entry, sid_hint)
        local info = vlan_sections[vid]
        if not info then
            -- 目标 VLAN 不存在就新建 section，并补齐 CPU 口与目标端口。
            local new_sid = write_switch_vlan(c, sid_hint, sw, vid, { cpu, entry })
            vlan_sections[vid] = { sid = new_sid, ports = { cpu, entry } }
            return
        end
        local ports = info.ports or {}
        local old_cnt = #ports
        list_add_unique(ports, cpu)
        list_add_unique(ports, entry)
        if #ports ~= old_cnt then
            save_ports_or_delete_if_cpu_only(vid, ports)
        end
    end

    if old_pvid and old_pvid ~= new_pvid then
        remove_entry_from_vlan(old_pvid, function(v)
            return v:match('^' .. p .. 'u?$') ~= nil
        end)
    end
    -- trunk+pvid=0 时不配 PVID（不写 untag 成员），untag 包丢弃。
    if cfg.vlan_mode ~= 'trunk' or new_pvid ~= 0 then
        ensure_entry_on_vlan(new_pvid, p, nil)
    else
        ensure_entry_on_vlan(4095, p, nil)
    end

    for vid in pairs(old_tags) do
        if not new_tags[vid] and vid ~= 4002 and vid ~= 4003 then
            remove_entry_from_vlan(vid, function(v)
                return v == p .. 't'
            end)
        end
    end
    for vid in pairs(new_tags) do
        if not old_tags[vid] then
            ensure_entry_on_vlan(vid, p .. 't', nil)
        end
    end

    sync_gsw_bridge_members_from_switch(c, cfg)
end

--- 功能：将单个 GSW WAN 配置下发到 network。
--- @param c table uci cursor
--- @param cfg table 端口配置（至少包含 switch/port）
--- @return nil
local function apply_gsw_wan(c, cfg)
    if not cfg.port then
        return
    end
    local keep_sids = {
        vlan_wan = true,
        vlan_secondwan = true,
    }
    remove_switch_vlans_for_port(c, cfg.switch, cfg.port, keep_sids, cfg.cpu_port)
    sync_gsw_bridge_members_from_switch(c, cfg)
end

--- 功能：按端口类型（DSA/GSW）与模式（LAN/WAN）分发下发函数。
--- @param c table uci cursor
--- @param name string 端口名
--- @param cfg table 端口配置
--- @return nil
local function apply_one_port_to_network(c, name, cfg)
    if not cfg or not cfg.type or not cfg.mode then
        return
    end
    if cfg.type == 'gsw' then
        -- GSW 与 DSA 下发流程不同，先按后端类型分流。
        if cfg.mode == 'lan' then
            apply_gsw_lan(c, cfg, name)
        else
            apply_gsw_wan(c, cfg)
        end
        return
    end

    if cfg.mode == 'lan' then
        apply_dsa_lan(c, cfg, name)
    else
        apply_dsa_wan(c, cfg)
    end
end

--- 功能：将单接口 map 配置应用到 network 并立即生效。
--- @param name string 端口名
--- @return boolean true 成功，false 失败
function M.apply_network_for_interface(name)
    local cfg = M.get_port_config_from_map(name)
    if not cfg then
        return false
    end
    local c = uci.cursor()
    local ok = pcall(function()
        -- 单接口场景也复用统一下发入口，保证行为一致。
        apply_one_port_to_network(c, name, cfg)
        c:commit('network')
    end)
    c:close()
    if not ok then
        return false
    end
    return true
end

--- 功能：一次性下发全部 map 端口配置并统一生效。
--- @return boolean true 成功，false 失败
function M.apply_network_from_eth_ports_config_map()
    local all = M.load_ports_config_from_map()
    local c = uci.cursor()
    local ok = pcall(function()
        -- 全量下发统一提交，避免“部分端口成功、部分端口失败”。
        for name, cfg in pairs(all) do
            apply_one_port_to_network(c, name, cfg)
        end
        c:commit('network')
    end)
    c:close()
    if not ok then
        return false
    end
    return true
end

--- 功能：将 map 中单个端口恢复为 LAN 口标准默认（access + pvid=1）。
--- @param c table uci cursor
--- @param sid string 端口 section id
--- @return nil
local function reset_map_port_lan_defaults(c, sid)
    c:set('eth_ports_config_map', sid, 'mode', 'lan')
    c:set('eth_ports_config_map', sid, 'vlan_mode', 'access')
    c:set('eth_ports_config_map', sid, 'pvid', '1')
    c:delete('eth_ports_config_map', sid, 'tagged_vlans')
    c:delete('eth_ports_config_map', sid, 'wan_type')
end

--- 功能：按网络模式调整 eth_ports_config_map 并全量下发 network。
--- @param mode string|nil 省略、空或非法值时按 ap；'s2s' 为 S2S
---   ap：非主 WAN（wan_type~=wan）口统一为 LAN 默认；
---   s2s：仅将当前已是 LAN 的口恢复为 LAN 标准默认，WAN 口不动。
--- @return boolean true 成功，false 失败
function M.apply_ap_mode_port_defaults(mode)
    if mode ~= nil then
        mode = tostring(mode):lower()
    end
    if not mode or mode == '' or (mode ~= 'ap' and mode ~= 's2s') then
        mode = 'ap'
    end

    local c = uci.cursor()
    local ok_commit = false

    local ok = pcall(function()
        for s in c:each('eth_ports_config_map', 'port') do
            local sid = s['.name']

            if mode == 'ap' then
                local wan_type = c:get('eth_ports_config_map', sid, 'wan_type')
                if wan_type ~= 'wan' then
                    reset_map_port_lan_defaults(c, sid)
                end
            elseif (c:get('eth_ports_config_map', sid, 'mode') or 'lan') == 'lan' then
                reset_map_port_lan_defaults(c, sid)
            end
        end

        if c.save then
            c:save('eth_ports_config_map')
        end
        ok_commit = c:commit('eth_ports_config_map')
    end)
    c:close()

    if not ok or not ok_commit then
        return false
    end

    return M.apply_network_from_eth_ports_config_map()
end

local function map_wan_netdev(cfg)
    if not cfg then
        return nil
    end
    if cfg.type == 'gsw' then
        local vid = tonumber(cfg.default_vlan)
        local base = cfg.main_interface
        return (vid and vid > 0 and base and base ~= '') and (base .. '.' .. vid) or nil
    end
    return cfg.port and tostring(cfg.port) or nil
end

local function map_logical_wan(cfg, logical)
    return cfg and cfg.mode == 'wan' and cfg.wan_type == logical
end

--- 按出厂 map 同步 wan/secondwan（须在 reset_ports_to_factory 之后调用）。
function M.sync_logical_wan_from_map(c)
    if not c then
        return
    end
    local net_key = c:get('network', 'lan', 'device') and 'device' or 'ifname'
    local wan_cfg = M.get_port_config_from_map('wan')
    local swan_cfg = M.get_port_config_from_map('secondwan')
    local gl = c:get('glconfig', 'general')
    if gl then
        c:set('glconfig', 'general', 'wan2lan', map_logical_wan(wan_cfg, 'wan') and '0' or '1')
        c:set('glconfig', 'general', 'lan2wan', map_logical_wan(swan_cfg, 'secondwan') and '1' or '0')
        c:delete('glconfig', 'general', 'wan')
        c:delete('glconfig', 'general', 'secondwan')
    end
    local bs = c:get_all('board_special')
    for _, iface in ipairs({ 'wan', 'secondwan' }) do
        local cfg = iface == 'wan' and wan_cfg or swan_cfg
        local ndev = map_logical_wan(cfg, iface) and map_wan_netdev(cfg) or nil
        if c:get('network', iface) and ndev then
            c:set('network', iface, net_key, ndev)
            if cfg.type == 'gsw' and cfg.switch and cfg.port then
                local vid = tonumber(cfg.default_vlan)
                if vid and vid > 0 and cfg.main_interface then
                    local dev_sid = iface .. '_dev'
                    write_switch_vlan(c, 'vlan_' .. iface, cfg.switch, vid,
                        { tostring(cfg.port), cfg.cpu_port or '0t' })
                    if not c:get('network', dev_sid) then
                        c:set('network', dev_sid, 'device')
                    end
                    c:set('network', dev_sid, 'name', ndev)
                    c:set('network', dev_sid, 'ifname', cfg.main_interface)
                    local mac = c:get('network', dev_sid, 'macaddr') or cfg.default_mac
                    if mac and mac ~= '' then
                        c:set('network', dev_sid, 'macaddr', mac)
                    end
                    for s in c:each('network', 'device') do
                        if s.name == ndev and s['.name'] ~= dev_sid and s.ifname then
                            c:delete('network', s['.name'])
                        end
                    end
                end
            end
            if bs then
                c:set('board_special', 'hardware', iface, ndev)
                local vid = cfg.type == 'gsw' and tonumber(cfg.default_vlan)
                if vid then
                    c:set('board_special', iface, 'vid', tostring(vid))
                end
            end
        end
    end
    c:commit("glconfig")
    c:commit("network")
    c:commit("board_special")
end

--- AP/WDS 切回路由：恢复端口 map/network，并同步逻辑 WAN UCI。
function M.on_netmode_to_router(c)
    if not M.reset_ports_to_factory() then
        return false
    end
    M.sync_logical_wan_from_map(c)
    return true
end

--- 功能：将所有端口恢复为出厂默认配置（与 gl-eth-ports.json 一致）。
--- 步骤：
--- 1) 从 gl-eth-ports.json 重建 eth_ports_config_map（等同 init_eth_ports_config_map）；
--- 2) 按重建后的 map 全量下发 network 配置。
--- @return boolean true 成功，false 失败
function M.reset_ports_to_factory()
    local ret = M.init_eth_ports_config_map()
    if ret ~= 0 then
        return false
    end
    return M.apply_network_from_eth_ports_config_map()
end

--- 功能：查询属于指定 eth VLAN 的 map 端口名列表。
--- @param eth_vlan string 形如 "eth0.20"
--- @return table 命中的端口名数组（去重）
function M.get_map_port_names_for_eth_vlan(eth_vlan)
    local out = {}
    local seen = {}
    if type(eth_vlan) ~= 'string' then
        return out
    end

    local base_if, vlan = eth_vlan:match('^(eth%d+)%.(%d+)$')
    if not base_if then
        base_if, vlan = eth_vlan:match('^(lan%d*)%.(%d+)$')
    end
    if not base_if then
        base_if, vlan = eth_vlan:match('^(wan)%.(%d+)$')
    end
    vlan = tonumber(vlan)
    if not base_if or not vlan then
        return out
    end

    local all = M.load_ports_config_from_map() or {}
    for _, cfg in pairs(all) do
        local name = cfg and cfg.name
        local cfg_vlan = tonumber(cfg and cfg.wan_vlan)
        if name and cfg_vlan == vlan then
            local is_match = false

            -- GSW 场景常见匹配：eth1.xx
            if tostring(cfg.main_interface or '') == base_if then
                is_match = true
            end

            -- DSA/兼容匹配
            if tostring(cfg.port or '') == base_if then
                is_match = true
            end

            if is_match and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
    end
    return out
end

--- 三可切 WAN 机型：若仅有一个 WAN 口且 wan_type=secondwan，完整提升为主 WAN。
--- 迁移覆盖: network interface / interface6 / device / switch_vlan / glconfig / board_special / eth_ports_config_map。
--- 不迁移 firewall (zone wan 已同时包含 wan 和 secondwan, 残留无害)。
function M.normalize_sole_wan_as_primary(c)
    local close_c = false
    if not c then c = uci.cursor(); close_c = true end

    -- 1. 前置检查: ≥3 可切 WAN, 恰好 1 个 WAN, 且 wan_type=secondwan
    local all = M.load_ports_config_from_map()
    if count_switchable_ports(all) < 3 then
        if close_c then c:close() end
        return false
    end

    local sole_name, sole_cfg
    for name, cfg in pairs(all) do
        if cfg.mode == 'wan' then
            if sole_name then
                if close_c then c:close() end
                return false
            end
            sole_name, sole_cfg = name, cfg
        end
    end
    if not sole_cfg or sole_cfg.wan_type ~= 'secondwan' then
        if close_c then c:close() end
        return false
    end

    -- 2. 快照 secondwan
    local sec     = c:get_all('network', 'secondwan') or {}
    local sec6    = c:get_all('network', 'secondwan6') or {}
    local sec_hw  = c:get('board_special', 'hardware', 'secondwan')
    local sec_vid = c:get('board_special', 'secondwan', 'vid')
    local sec_gl  = c:get('glconfig', 'general', 'secondwan')

    local dev_name = sec.device or sec.ifname
    local sec_dev  = nil
    if dev_name then
        for s in c:each('network', 'device') do
            if s.name == dev_name then
                sec_dev = c:get_all('network', s['.name']) or {}
                break
            end
        end
    end

    -- 3. network interface: 清空 wan 旧字段, secondwan 全量写入
    for k in pairs(c:get_all('network', 'wan') or {}) do
        if k:sub(1,1) ~= '.' then c:delete('network', 'wan', k) end
    end
    for k, v in pairs(sec) do
        if v and v ~= '' and k:sub(1,1) ~= '.' then
            c:set('network', 'wan', k, v)
        end
    end

    -- 4. network interface6: 仅 secondwan6 存在时才迁移 (否则不碰 wan6)
    if sec6.proto then
        for k in pairs(c:get_all('network', 'wan6') or {}) do
            if k:sub(1,1) ~= '.' then c:delete('network', 'wan6', k) end
        end
        for k, v in pairs(sec6) do
            if v and v ~= '' and k:sub(1,1) ~= '.' then
                c:set('network', 'wan6', k, v)
            end
        end
        for _, k in ipairs({'device', 'ifname'}) do
            if c:get('network', 'wan6', k) == '@secondwan' then
                c:set('network', 'wan6', k, '@wan')
            end
        end
    end

    -- 5. secondwan section: 保留角色级配置, 只清除设备绑定
    c:delete('network', 'secondwan', 'device')
    c:delete('network', 'secondwan', 'ifname')


    -- 6. device section: GSW 的 secondwan_dev → wan_dev (DSA 跟物理口走, 不迁移)
    if sec_dev and sole_cfg.type == 'gsw' then
        c:delete('network', 'wan_dev')
        c:set('network', 'wan_dev', 'device')
        for k, v in pairs(sec_dev) do
            if v and v ~= '' and k:sub(1,1) ~= '.' then
                c:set('network', 'wan_dev', k, v)
            end
        end
        for s in c:each('network', 'device') do
            if s.name == dev_name then c:delete('network', s['.name']); break end
        end
    end

    -- 7. GSW switch_vlan
    if sole_cfg.type == 'gsw' and sole_cfg.switch and sole_cfg.port then
        local vid = tonumber(sole_cfg.wan_vlan)
        if not vid or vid <= 0 then
            vid = tonumber(sole_cfg.default_vlan)
        end
        if vid and vid > 0 then
            local ports = { tostring(sole_cfg.port), sole_cfg.cpu_port or '0t' }
            for s in c:each('network', 'switch_vlan') do
                if s['.name'] == 'vlan_secondwan' then
                    local sp = type(s.ports) == 'table' and s.ports or split_ws(s.ports)
                    if sp and #sp > 0 then ports = sp end
                    break
                end
            end
            c:delete('network', 'vlan_secondwan')
            write_switch_vlan(c, 'vlan_wan', sole_cfg.switch, vid, ports)
        end
    end

    -- 8. board_special + glconfig + eth_ports_config_map
    if sec_hw  then c:set('board_special', 'hardware', 'wan', sec_hw) end
    if sec_vid then c:set('board_special', 'wan', 'vid', sec_vid) end
    c:delete('board_special', 'hardware', 'secondwan')
    c:delete('board_special', 'secondwan', 'vid')

    c:set('glconfig', 'general', 'wan2lan', '0')
    c:set('glconfig', 'general', 'lan2wan', '0')
    if sec_gl then c:set('glconfig', 'general', 'wan', sec_gl) end
    c:delete('glconfig', 'general', 'secondwan')

    c:set('eth_ports_config_map', sole_name:gsub('[^%w_-]', '_'), 'wan_type', 'wan')

    -- 9. 统一提交
    if c.save then c:save('eth_ports_config_map') end
    c:commit('eth_ports_config_map')
    c:commit('network')
    c:commit('glconfig')
    c:commit('board_special')

    if close_c then c:close() end
    return true
end

--- 功能：将所有LAN口以 tagged 方式绑定到指定 VLAN bridge。
--- @param bridge_name string 桥名，如 "guest"、"iot" 或全名 "br-guest"、"br-iot"
--- @param vid number|string VLAN ID
--- @return boolean true 成功，false 失败
function M.bind_all_ports_tagged_to_bridge(bridge_name, vid)
    if not bridge_name or bridge_name == '' or not vid then
        return false
    end
    local v = tonumber(vid)
    if v ~= 4002 and v ~= 4003 then
        return false
    end

    local br_name = tostring(bridge_name)
    if not br_name:match('^br%-') then
        br_name = 'br-' .. br_name
    end

    local all_ports = M.load_ports_config_from_map()
    if not all_ports or not next(all_ports) then
        return false
    end

    local c = uci.cursor()

    local br_sid = find_device_sid_by_name(c, br_name)
    if not br_sid then
        br_sid = alloc_device_sid(c, br_name)
        c:set('network', br_sid, 'device')
        c:set('network', br_sid, 'name', br_name)
        c:set('network', br_sid, 'type', 'bridge')
    end

    local iface = interface_name_by_bridge(br_name) or br_name:gsub('^br%-', '')
    if not c:get('network', iface) then
        c:set('network', iface, 'interface')
        c:set('network', iface, 'proto', 'static')
    end
    c:set('network', iface, 'device', br_name)

    local br_ports = read_device_ports(c, br_sid)

    for _, cfg in pairs(all_ports) do
        if cfg.mode == 'lan' and cfg.type == 'gsw' and cfg.main_interface and cfg.port then
            local mi, pn = tostring(cfg.main_interface), tostring(cfg.port)
            local cpu = cfg.cpu_port or '0t'
            local dev = mi .. '.' .. tostring(v)
            ensure_gsw_device(c, dev, mi, v)

            local sid = nil
            for s in c:each('network', 'switch_vlan') do
                if (cfg.switch == nil or s.device == cfg.switch) and tonumber(s.vlan) == v then
                    sid = s['.name']
                    break
                end
            end
            if sid then
                local vp = read_device_ports(c, sid)
                list_add_unique(vp, cpu)
                list_add_unique(vp, pn .. 't')
                set_switch_vlan_ports(c, sid, vp)
            else
                write_switch_vlan(c, nil, cfg.switch, v, { cpu, pn .. 't' })
            end
            list_add_unique(br_ports, dev)
        elseif cfg.mode == 'lan' and cfg.type ~= 'gsw' and cfg.port then
            list_add_unique(br_ports, ensure_dsa_vlan_device(c, tostring(cfg.port), v))
        end
    end

    set_opt_list(c, 'network', br_sid, 'ports', br_ports)
    if c:get('network', iface, 'disabled') == '1' then
        c:set('network', iface, 'disabled', '0')
    end

    c:commit('network')
    c:close()
    os.execute('/etc/init.d/network reload 2>/dev/null')
    return true
end

--- 功能：将所有端口从指定 VLAN bridge 解绑（tagged 方式移除）。
--- @param bridge_name string 桥名
--- @param vid number|string VLAN ID（仅允许 4002 或 4003）
--- @return boolean true 成功，false 失败
function M.unbind_all_ports_tagged_from_bridge(bridge_name, vid)
    if not bridge_name or bridge_name == '' or not vid then
        return false
    end
    local v = tonumber(vid)
    if v ~= 4002 and v ~= 4003 then
        return false
    end

    local br_name = tostring(bridge_name)
    if not br_name:match('^br%-') then
        br_name = 'br-' .. br_name
    end

    local all_ports = M.load_ports_config_from_map()
    if not all_ports or not next(all_ports) then
        return false
    end

    local c = uci.cursor()
    local br_sid = find_device_sid_by_name(c, br_name)
    if not br_sid then
        c:close()
        return true
    end

    local br_ports = read_device_ports(c, br_sid)

    for _, cfg in pairs(all_ports) do
        if cfg.mode == 'lan' and cfg.port then
            local dev
            if cfg.type == 'gsw' and cfg.main_interface then
                dev = tostring(cfg.main_interface) .. '.' .. tostring(v)
                for s in c:each('network', 'switch_vlan') do
                    if (cfg.switch == nil or s.device == cfg.switch) and tonumber(s.vlan) == v then
                        local vp, filtered = read_device_ports(c, s['.name']), {}
                        for _, x in ipairs(vp) do
                            if tostring(x) ~= tostring(cfg.port) .. 't' then
                                filtered[#filtered + 1] = x
                            end
                        end
                        set_switch_vlan_ports(c, s['.name'], filtered)
                        break
                    end
                end
            elseif cfg.type ~= 'gsw' then
                dev = tostring(cfg.port) .. '.' .. tostring(v)
            end
            if dev then
                local dev_sid = find_device_sid_by_name(c, dev)
                if dev_sid then c:delete('network', dev_sid) end
                br_ports = list_remove_if(br_ports, function(x) return tostring(x) == dev end)
            end
        end
    end

    for s in c:each('network', 'switch_vlan') do
        if tonumber(s.vlan) == v then c:delete('network', s['.name']) end
    end

    set_opt_list(c, 'network', br_sid, 'ports', br_ports)
    if #br_ports == 0 then
        disable_guest_iot_if_wifi_off(c, br_name)
    end
    c:commit('network')
    c:close()
    os.execute('/etc/init.d/network reload 2>/dev/null')
    return true
end

return M
