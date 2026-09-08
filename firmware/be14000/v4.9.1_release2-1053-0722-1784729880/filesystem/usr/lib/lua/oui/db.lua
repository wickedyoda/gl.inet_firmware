local sqlite3 = require "lsqlite3"

local M = {}

local DB = "/etc/oui/oui.db"

local function valid_username(username)
    return type(username) == "string" and username:match('^[a-z][-a-z0-9_]*$') and true
end

M.init = function()
    local db = sqlite3.open(DB)
    db:exec("CREATE TABLE IF NOT EXISTS account(username TEXT PRIMARY KEY NOT NULL, acl TEXT NOT NULL)")
    db:close()
end

M.get_acl_by_username = function(username)
    if not valid_username(username) then return nil, "invalid username" end

    if username == "root" then return "root" end

    local db = sqlite3.open(DB)
    local sql = string.format("SELECT acl FROM account WHERE username = '%s'", username)

    local aclgroup = ""

    for a in db:rows(sql) do
        aclgroup = a[1]
    end

    db:close()

    return aclgroup
end

M.add_user = function(username)
    if not valid_username(username) then return false, "invalid username" end

    local db = sqlite3.open(DB)

    local found = false

    db:exec(string.format("SELECT acl FROM account WHERE username = %s", username), function() found = true end)

    if not found then
        db:exec(string.format("INSERT INTO account VALUES('%s', '%s')", username, username == "root" and "root" or ""))
    end

    db:close()

    return true
end

M.get_perm = function(aclgroup, scope, entry)
    local db = sqlite3.open(DB)

    local sql = string.format("SELECT permissions FROM acl_%s WHERE scope = '%s' AND entry = '%s'", aclgroup, scope, entry)
    local perm = ""

    db:exec(sql, function(udata, cols, values, names)
        perm = values[1]
        return 1
    end)

    db:close()

    return perm
end

return M
