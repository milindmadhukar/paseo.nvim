--- Configured Paseo hosts and the small amount of session-local state around them.
---
--- A configured alias is how humans address a host. The daemon's `serverId` is
--- its canonical identity once a connection has completed. Both are retained:
--- aliases keep setup readable, while server IDs prevent resources from two
--- daemons with coincidentally equal agent IDs from becoming the same thing.

local config = require "paseo.config"

local M = {}

---@class paseo.Host
---@field id string Config alias.
---@field label string
---@field connections table[]
---@field paths table[]
---@field provider string|nil
---@field local_host boolean
---@field server_id string|nil
---@field hostname string|nil
---@field version string|nil
---@field status "idle"|"connecting"|"online"|"offline"|"error"
---@field error string|nil
---@field active_connection string|nil
---@field latency integer|nil

---@type table<string, paseo.Host>
local profiles = {}
local order = {}
local selected
local session_filter
local listeners = {}

local function clean(path)
  return vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/+$", "")
end

local function secret(value)
  if type(value) == "function" then
    local ok, resolved = pcall(value)
    return ok and type(resolved) == "string" and resolved or nil
  end
  return type(value) == "string" and value or nil
end

M.secret = secret

local function websocket(address, tls)
  address = vim.trim(address or "")
  address = address:gsub("^tcp://", "")
  if address:match "^wss?://" then
    return address:match "/ws/?$" and address or (address:gsub("/+$", "") .. "/ws")
  end
  return ((tls and "wss://" or "ws://") .. address:gsub("/+$", "") .. "/ws")
end

local function offer(value)
  local link = secret(value)
  if not link or link == "" then
    return nil, "relay pairing link is empty"
  end
  local encoded = link:match "#offer=([^&%s]+)"
  if not encoded then
    return nil, "relay pairing link has no #offer fragment"
  end
  encoded = encoded:gsub("-", "+"):gsub("_", "/")
  encoded = encoded .. string.rep("=", (4 - #encoded % 4) % 4)
  local ok, decoded = pcall(vim.base64.decode, encoded)
  if not ok then
    return nil, "relay pairing offer is not valid base64"
  end
  local parsed_ok, parsed = pcall(vim.json.decode, decoded)
  if
    not parsed_ok
    or type(parsed) ~= "table"
    or parsed.v ~= 2
    or type(parsed.serverId) ~= "string"
    or type(parsed.daemonPublicKeyB64) ~= "string"
    or type(parsed.relay) ~= "table"
    or type(parsed.relay.endpoint) ~= "string"
  then
    return nil, "relay pairing offer is invalid"
  end
  local endpoint = parsed.relay.endpoint
  local tls = parsed.relay.useTls
  if tls == nil then
    tls = endpoint:match ":443$" ~= nil
  end
  local url = websocket(endpoint, tls)
  local separator = url:find "?" and "&" or "?"
  url = url
    .. separator
    .. "serverId="
    .. vim.uri_encode(parsed.serverId)
    .. "&role=client&v=2"
  return {
    url = url,
    expectedServerId = parsed.serverId,
    e2ee = { enabled = true, daemonPublicKeyB64 = parsed.daemonPublicKeyB64 },
  }
end

---Turn one public connection definition into sidecar connection options.
---Secrets are resolved here, at connection time, and never retained in host state.
---@param connection table
---@return table|nil, string|nil
function M.connection_options(connection)
  if connection.type == "direct" then
    return {
      url = websocket(connection.address, connection.tls == true),
      password = secret(connection.password),
    }
  end
  if connection.type == "relay" then
    return offer(connection.offer)
  end
  return nil, "local connections are resolved by paseo.daemon"
end

local function legacy()
  local paseo = config.get().paseo
  return {
    id = "local",
    label = "Local",
    connections = { {
      id = "local",
      type = "local",
      url = paseo.url,
      password = paseo.password,
      home = paseo.home,
      autostart = paseo.autostart,
    } },
    paths = {},
    provider = paseo.provider,
    local_host = true,
    status = "idle",
  }
end

---Rebuild profiles after setup. Runtime fields survive when aliases survive.
function M.setup()
  local old = profiles
  profiles, order = {}, {}
  local configured = config.get().paseo.hosts
  if not configured then
    local host = legacy()
    profiles["local"], order[1] = host, "local"
  else
    for alias, raw in pairs(configured) do
      local connections = {}
      local local_host = false
      for i, connection in ipairs(raw.connections) do
        local copy = vim.deepcopy(connection)
        copy.id = copy.id or (copy.type .. "-" .. i)
        local_host = local_host or copy.type == "local"
        connections[#connections + 1] = copy
      end
      local mappings = {}
      for _, mapping in ipairs(raw.paths or {}) do
        mappings[#mappings + 1] = {
          local_root = clean(mapping.local_root),
          remote_root = mapping.remote_root:gsub("/+$", ""),
        }
      end
      table.sort(mappings, function(a, b)
        return #a.local_root > #b.local_root
      end)
      local previous = old[alias] or {}
      profiles[alias] = {
        id = alias,
        label = raw.label or alias,
        connections = connections,
        paths = mappings,
        provider = raw.provider,
        local_host = local_host,
        server_id = previous.server_id,
        hostname = previous.hostname,
        version = previous.version,
        status = previous.status or "idle",
        error = previous.error,
        active_connection = previous.active_connection,
        latency = previous.latency,
      }
      order[#order + 1] = alias
    end
    table.sort(order)
  end
  selected = config.get().paseo.default_host or selected
  if not selected or not profiles[selected] then
    selected = profiles["local"] and "local" or order[1]
  end
  if not session_filter or (session_filter ~= "*" and not profiles[session_filter]) then
    session_filter = #order > 1 and "*" or selected
  end
end

local function ensure_setup()
  if #order == 0 then
    M.setup()
  end
end

---@return paseo.Host[]
function M.all()
  ensure_setup()
  local out = {}
  for _, id in ipairs(order) do
    out[#out + 1] = profiles[id]
  end
  return out
end

function M.count()
  ensure_setup()
  return #order
end

function M.multiple()
  return M.count() > 1
end

---@param id? string
---@return paseo.Host|nil
function M.get(id)
  ensure_setup()
  if not id then
    id = selected
  end
  if profiles[id] then
    return profiles[id]
  end
  for _, host in pairs(profiles) do
    if host.server_id == id then
      return host
    end
  end
end

function M.selected()
  ensure_setup()
  return selected
end

---@param id string
---@return boolean, string|nil
function M.select(id)
  local host = M.get(id)
  if not host then
    return false, ("unknown Paseo host %q"):format(tostring(id))
  end
  selected = host.id
  for _, fn in ipairs(listeners) do
    pcall(fn, host)
  end
  return true, nil
end

function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

function M.filter()
  ensure_setup()
  return M.multiple() and session_filter or selected
end

function M.set_filter(id)
  ensure_setup()
  if id ~= "*" and not profiles[id] then
    return false, ("unknown Paseo host %q"):format(tostring(id))
  end
  session_filter = M.multiple() and id or selected
  for _, fn in ipairs(listeners) do
    pcall(fn, profiles[selected])
  end
  return true
end

---@param id string
---@param fields table
function M.update(id, fields)
  local host = M.get(id)
  if not host then
    return
  end
  if fields.server_id then
    for _, other in pairs(profiles) do
      if other ~= host and other.server_id == fields.server_id then
        fields = vim.tbl_extend("force", fields, {
          status = "error",
          error = ("serverId %s is already configured as %s"):format(fields.server_id, other.id),
        })
      end
    end
  end
  for key, value in pairs(fields) do
    if value == vim.NIL then
      host[key] = nil
    else
      host[key] = value
    end
  end
  for _, fn in ipairs(listeners) do
    pcall(fn, host)
  end
end

local function translate(path, from, to, mappings)
  if not path or path == "" then
    return nil
  end
  path = path:gsub("/+$", "")
  local best
  for _, mapping in ipairs(mappings or {}) do
    local prefix = mapping[from]
    if path == prefix or vim.startswith(path, prefix .. "/") then
      if not best or #prefix > #best[from] then
        best = mapping
      end
    end
  end
  if not best then
    return nil
  end
  return best[to] .. path:sub(#best[from] + 1)
end

---@param id string
---@param path string
---@return string|nil
function M.to_remote(id, path)
  local host = M.get(id)
  if not host then
    return nil
  end
  if host.local_host then
    return clean(path)
  end
  return translate(clean(path), "local_root", "remote_root", host.paths)
end

---@param id string
---@param path string
---@return string|nil
function M.to_local(id, path)
  local host = M.get(id)
  if not host then
    return nil
  end
  if host.local_host then
    return clean(path)
  end
  return translate(path, "remote_root", "local_root", host.paths)
end

---@param id string
---@param resource_id string
function M.key(id, resource_id)
  local host = M.get(id)
  return ((host and host.server_id) or id) .. ":" .. resource_id
end

function M.reset()
  profiles, order, selected, session_filter = {}, {}, nil, nil
end

return M
