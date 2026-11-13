--- What the source may not say.
---
--- Greps over the modules themselves, for the tools they refuse to use.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local sidecar_source = t.sidecar_source
local render = require "paseo.ui.render"

local function test_invariants()
  -- ---------------------------------------------------- source invariants

  -- NOT `vim.fn.getcwd()`: the review and ws-init suites `tcd` into fixture
  -- directories, so by the time this runs the cwd is wherever they left it and
  -- every one of these assertions silently skipped instead of failing.
  local root_dir =
    vim.fs.dirname(vim.api.nvim_get_runtime_file("lua/paseo/ui/render.lua", false)[1])
  root_dir = root_dir and vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(root_dir)))

  local function source_of(path)
    if not root_dir then
      return nil
    end
    local fd = io.open(root_dir .. "/" .. path, "r")
    if not fd then
      return nil
    end
    local text = fd:read "*a"
    fd:close()
    return text
  end

  truthy("ui: the source tree under test was located", root_dir ~= nil)

  local sidecar = sidecar_source()
  if sidecar then
    -- The root cause of "I can't see the thinking steps": the sidecar's switch
    -- forwarded only assistant_message and user_message and dropped the rest.
    truthy("ui: the sidecar forwards reasoning", sidecar:find('case "reasoning"', 1, true) ~= nil)
    truthy("ui: the sidecar forwards tool calls", sidecar:find('case "tool_call"', 1, true) ~= nil)
    truthy(
      "ui: the sidecar forwards permission requests",
      sidecar:find('case "permission_requested"', 1, true) ~= nil
    )
    truthy(
      "ui: history carries tool calls too, through the same describer",
      sidecar:find("describeItem(entry.item", 1, true) ~= nil
    )
    -- A synthesised action id is ours, not the provider's, and sending one back
    -- is rejected.
    truthy(
      "ui: synthetic action ids are stripped before answering",
      sidecar:find('startsWith("__")', 1, true) ~= nil
    )
  end

  local chat_source = source_of "lua/paseo/ui/chat.lua"
  if chat_source then
    truthy(
      "ui: the replaced event is handled",
      chat_source:find('bridge.on("replaced"', 1, true) ~= nil
    )
  end

  -- THE RESIZE WATCH IS GLOBAL, and pinned here because the buffer-local
  -- version looked correct and silently did nothing. `WinResized`'s pattern is
  -- the window-ID of the FIRST window that resized, and a buffer-local autocmd
  -- is matched against that window's buffer -- so the default right-hand
  -- sidebar, which sorts last, never fired it at all.
  if chat_source then
    truthy(
      "ui: the transcript resize watch is global and in its own augroup",
      chat_source:find('nvim_create_augroup(\n    "paseo.chat.resize.', 1, true) ~= nil
    )
    truthy(
      "ui: and debounced rather than run per column of a drag",
      chat_source:find("chat.resize_pending", 1, true) ~= nil
    )
  end

  -- The other half: a redraw the width did not change writes nothing.
  local transcript_source = source_of "lua/paseo/ui/transcript.lua"
  if transcript_source then
    truthy(
      "ui: the transcript guards a redraw on the width it last drew at",
      transcript_source:find("chat.rendered_width == width", 1, true) ~= nil
    )
  end

  -- NO UI LIBRARY. Every surface is plain buffers drawn by |paseo.ui.render|;
  -- nvzone/volt drew the old dashboard and is gone with it. A `require` of it
  -- would only fail on a machine that does not happen to have it installed.
  local requiring = {}
  for _, path in ipairs(vim.fn.glob(root_dir .. "/lua/**/*.lua", false, true)) do
    local fd = io.open(path, "r")
    if fd then
      local text = fd:read "*a"
      fd:close()
      if text:find('require%s*%(?%s*"volt') or text:find("require%s*%(?%s*'volt") then
        requiring[#requiring + 1] = path:sub(#root_dir + 2)
      end
    end
  end
  table.sort(requiring)
  eq("ui: nothing requires volt", requiring, {})
  eq("ui: and the dashboard it drew is gone", vim.uv.fs_stat(root_dir .. "/lua/paseo/ui/float.lua"), nil)

  -- The overlay's architecture, pinned so it cannot quietly re-couple. It
  -- takes callbacks rather than reaching for the daemon,
  -- which is what keeps `permission -> ask` one-way and lets the spec above drive
  -- it with stubs. And it types into a real buffer, which is the whole point of
  -- the inline box over the `vim.ui.input` it replaced.
  ---Source with the comments taken out. These modules EXPLAIN what they refuse to
  ---do -- `ask.lua` says in prose why `vim.ui.input` is the wrong tool -- and
  ---a grep over the prose finds the words it is looking for in
  ---the sentence saying they are absent.
  ---@param path string
  ---@return string|nil
  local function code_of(path)
    local text = source_of(path)
    if not text then
      return nil
    end
    local kept = {}
    for line in (text .. "\n"):gmatch "(.-)\n" do
      if not line:match "^%s*%-%-" then
        kept[#kept + 1] = line
      end
    end
    return table.concat(kept, "\n")
  end

  local ask_source = code_of "lua/paseo/ui/answer.lua"
  if ask_source then
    truthy("ui: nor talks to the daemon itself", ask_source:find("paseo.bridge", 1, true) == nil)
    truthy(
      "ui: and answers in a buffer rather than a prompt",
      ask_source:find("vim.ui.input", 1, true) == nil
    )
  end
  local permission_source = code_of "lua/paseo/ui/permission.lua"
  if permission_source then
    truthy(
      "ui: and the dialog it was carved out of no longer prompts either",
      permission_source:find("vim.ui.input", 1, true) == nil
    )
  end

  -- THE DELETED SURFACE STAYS DELETED. `ui/termfloat.lua` was the rail-and-pane
  -- window a terminal used to open in; a terminal is a session on the Chat tab
  -- now, and a `require` of it would fail at the call site rather than here --
  -- inside a keymap, on a surface that is otherwise working.
  local resurrected = {}
  for _, path in ipairs(vim.fn.glob(root_dir .. "/lua/**/*.lua", false, true)) do
    local fd = io.open(path, "r")
    if fd then
      local text = fd:read "*a"
      fd:close()
      if text:find "paseo%.ui%.termfloat" then
        resurrected[#resurrected + 1] = path:sub(#root_dir + 2)
      end
    end
  end
  table.sort(resurrected)
  eq("ui: nothing requires the terminal surface that was deleted", resurrected, {})
  eq(
    "ui: and the file itself is gone",
    vim.uv.fs_stat(root_dir .. "/lua/paseo/ui/termfloat.lua"),
    nil
  )
end

return {
  { "ui.invariants", test_invariants },
}
