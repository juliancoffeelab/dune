local M = {}

local function log_path()
  return os.getenv("SMOKE_LOG")
end

local function append_log(kind, payload)
  local path = log_path()
  if not path or path == "" then
    return
  end

  local record = {
    kind = kind,
    payload = payload,
    time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }

  local line = vim.json.encode(record) .. "\n"
  local fd = assert(io.open(path, "a"))
  fd:write(line)
  fd:close()
end

local function fail(message)
  append_log("failure", { message = message })
  error(message)
end

local function current_path()
  return vim.api.nvim_buf_get_name(0)
end

local function attached_clients(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr or 0 })
end

local function wait_for_lsp(timeout_ms)
  local deadline = vim.loop.now() + timeout_ms
  while vim.loop.now() < deadline do
    if #attached_clients(0) > 0 then
      return true
    end
    vim.wait(100)
  end
  return #attached_clients(0) > 0
end

local function make_position_params()
  return vim.lsp.util.make_position_params()
end

local function collect_locations(responses)
  local locations = {}
  for _, response in pairs(responses or {}) do
    local result = response.result
    if result then
      if not vim.islist(result) then
        result = { result }
      end
      for _, location in ipairs(result) do
        table.insert(locations, location)
      end
    end
  end
  return locations
end

local function location_parts(location)
  local uri = location.uri or location.targetUri
  local range = location.range or location.targetSelectionRange
  if not range then
    range = location.targetRange
  end
  if not uri or not range then
    fail("Location missing uri or range")
  end
  return uri, range
end

local function jump_to_location(location)
  local uri, range = location_parts(location)
  local path = vim.uri_to_fname(uri)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(
    0,
    { range.start.line + 1, range.start.character }
  )
  return path
end

local function request_sync(method, timeout_ms)
  local responses = vim.lsp.buf_request_sync(
    0,
    method,
    make_position_params(),
    timeout_ms
  )
  if not responses or vim.tbl_isempty(responses) then
    fail("No LSP response for " .. method)
  end
  return responses
end

local function check_path_expectation(path)
  local pattern = os.getenv("SMOKE_EXPECT_PATH_REGEX")
  if not pattern or pattern == "" then
    return
  end
  if not string.match(path, pattern) then
    fail("Path does not match expectation: " .. path)
  end
end

local function goto_definition(timeout_ms)
  local responses = request_sync("textDocument/definition", timeout_ms)
  local locations = collect_locations(responses)
  if #locations == 0 then
    fail("Definition request returned no locations")
  end

  local path = jump_to_location(locations[1])
  append_log("definition", {
    location_count = #locations,
    path = path,
  })
  check_path_expectation(path)
  return path
end

local function hover_check(timeout_ms)
  local responses = request_sync("textDocument/hover", timeout_ms)
  for _, response in pairs(responses) do
    local result = response.result
    if result and result.contents then
      append_log("hover", { ok = true, path = current_path() })
      return true
    end
  end
  fail("Hover request returned no contents")
end

local function definition_check(timeout_ms)
  local responses = request_sync("textDocument/definition", timeout_ms)
  local locations = collect_locations(responses)
  if #locations == 0 then
    fail("Second definition request returned no locations")
  end
  append_log("definition-check", {
    location_count = #locations,
    path = current_path(),
  })
  return true
end

local function move_to_second_position()
  local line = tonumber(os.getenv("SMOKE_AFTER_LINE") or "")
  local col = tonumber(os.getenv("SMOKE_AFTER_COL") or "")
  if not line or not col then
    return
  end

  vim.api.nvim_win_set_cursor(0, { line, col - 1 })
  append_log("second-position", {
    line = line,
    col = col,
    path = current_path(),
  })
end

local function status()
  local clients = {}
  for _, client in ipairs(attached_clients(0)) do
    table.insert(clients, {
      id = client.id,
      name = client.name,
      root_dir = client.config.root_dir,
    })
  end
  append_log("status", {
    clients = clients,
    path = current_path(),
  })
  print(vim.inspect({
    clients = clients,
    path = current_path(),
  }))
end

local function start_ocamllsp()
  local cmd = os.getenv("OCAMLLSP_BIN")
  if not cmd or cmd == "" then
    fail("OCAMLLSP_BIN is not set")
  end

  local path = current_path()
  if path == "" then
    return
  end

  local root = vim.fs.root(path, {
    "dune-project",
    "dune-workspace",
    ".git",
  })
  if not root then
    root = vim.fs.dirname(path)
  end

  vim.lsp.start({
    cmd = { cmd },
    name = "ocamllsp",
    root_dir = root,
  })
end

function M.setup()
  local group = vim.api.nvim_create_augroup("dune_nvim_outside_lsp", {})

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = {
      "ocaml",
      "ocamlinterface",
      "dune",
      "menhir",
    },
    callback = start_ocamllsp,
  })

  vim.api.nvim_create_user_command("SmokeStatus", status, {})
  vim.api.nvim_create_user_command("SmokeGotoDef", function()
    goto_definition(15000)
  end, {})
  vim.api.nvim_create_user_command("SmokeHoverCheck", function()
    hover_check(15000)
  end, {})
  vim.api.nvim_create_user_command("SmokeDefinitionCheck", function()
    definition_check(15000)
  end, {})
  vim.api.nvim_create_user_command("SmokeLogPath", function()
    print(log_path() or "")
  end, {})
end

function M.run_headless()
  local line = tonumber(os.getenv("SMOKE_LINE") or "")
  local col = tonumber(os.getenv("SMOKE_COL") or "")
  local second = os.getenv("SMOKE_SECOND_ACTION") or "hover"

  append_log("headless-start", {
    path = current_path(),
    second = second,
  })

  if not wait_for_lsp(15000) then
    fail("Timed out waiting for LSP in initial buffer")
  end

  if not line or not col then
    fail("SMOKE_LINE and SMOKE_COL are required in headless mode")
  end

  vim.api.nvim_win_set_cursor(0, { line, col - 1 })
  goto_definition(15000)

  if not wait_for_lsp(15000) then
    fail("Timed out waiting for LSP in dependency buffer")
  end

  move_to_second_position()

  if second == "hover" then
    hover_check(15000)
  elseif second == "definition" then
    definition_check(15000)
  else
    fail("Unknown second action: " .. second)
  end

  append_log("headless-success", { path = current_path() })
  vim.cmd("qa!")
end

return M
