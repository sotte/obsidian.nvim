local Path = require "plenary.path"

local echo = require "obsidian.echo"
local config = require "obsidian.config"

local obsidian = {}

obsidian.VERSION = "1.15.0"
obsidian.completion = require "obsidian.completion"
obsidian.note = require "obsidian.note"
obsidian.util = require "obsidian.util"
obsidian.yaml = require "obsidian.yaml"
obsidian.mapping = require "obsidian.mapping"
obsidian.workspace = require "obsidian.workspace"

---@class obsidian.Client
---@field current_workspace obsidian.Workspace
---@field dir Path
---@field templates_dir Path|?
---@field opts obsidian.config.ClientOpts
---@field backlinks_namespace integer
local client = {}

---Create a new Obsidian client without additional setup.
---
---@param opts obsidian.config.ClientOpts
---@return obsidian.Client
obsidian.new = function(opts)
  local self = setmetatable({}, { __index = client })

  self.current_workspace = obsidian.workspace.get_from_opts(opts)
  -- NOTE: workspace.path has already been normalized
  self.dir = Path:new(self.current_workspace.path)
  self.opts = opts
  self.backlinks_namespace = vim.api.nvim_create_namespace "ObsidianBacklinks"
  if self.opts.yaml_parser ~= nil then
    obsidian.yaml.set_parser(self.opts.yaml_parser)
  end

  return self
end

---Create a new Obsidian client in a given vault directory.
---
---@param dir string
---@return obsidian.Client
obsidian.new_from_dir = function(dir)
  local opts = config.ClientOpts.default()
  opts.workspaces = vim.tbl_extend("force", { obsidian.workspace.new_from_dir(dir) }, opts.workspaces)
  return obsidian.new(opts)
end

---Setup a new Obsidian client.
---
---@param opts obsidian.config.ClientOpts
---@return obsidian.Client
obsidian.setup = function(opts)
  opts = config.ClientOpts.normalize(opts)
  local self = obsidian.new(opts)

  -- Ensure directories exist.
  self.dir:mkdir { parents = true, exists_ok = true }
  vim.cmd("set path+=" .. vim.fn.fnameescape(tostring(self.dir)))

  if self.opts.notes_subdir ~= nil then
    local notes_subdir = self.dir / self.opts.notes_subdir
    notes_subdir:mkdir { parents = true, exists_ok = true }
    vim.cmd("set path+=" .. vim.fn.fnameescape(tostring(notes_subdir)))
  end

  if self.opts.daily_notes.folder ~= nil then
    local daily_notes_subdir = self.dir / self.opts.daily_notes.folder
    daily_notes_subdir:mkdir { parents = true, exists_ok = true }
    vim.cmd("set path+=" .. vim.fn.fnameescape(tostring(daily_notes_subdir)))
  end

  self.templates_dir = nil
  if self.opts.templates ~= nil and self.opts.templates.subdir ~= nil then
    self.templates_dir = Path:new(self.dir) / self.opts.templates.subdir
    if not self.templates_dir:is_dir() then
      echo.err(string.format("%s is not a valid directory for templates", self.templates_dir), self.opts.log_level)
      self.templates_dir = nil
    end
  end

  -- Register commands.
  require("obsidian.command").register_all(self)

  -- Register mappings.
  for mapping_keys, mapping_config in pairs(opts.mappings) do
    vim.keymap.set("n", mapping_keys, mapping_config.action, mapping_config.opts)
  end

  --- @type fun(match: string): boolean
  local is_template
  if self.templates_dir ~= nil then
    local templates_pattern = tostring(self.templates_dir)
    templates_pattern = obsidian.util.escape_magic_characters(templates_pattern)
    templates_pattern = "^" .. templates_pattern .. ".*"
    is_template = function(match)
      return string.find(match, templates_pattern) ~= nil
    end
  else
    is_template = function(_)
      return false
    end
  end

  -- Register autocommands.
  local group = vim.api.nvim_create_augroup("obsidian_setup", { clear = true })

  if opts.completion.nvim_cmp then
    -- Inject Obsidian as a cmp source when reading a buffer in the vault.
    local cmp_setup = function()
      local cmp = require "cmp"
      local sources = {
        { name = "obsidian", option = opts },
        { name = "obsidian_new", option = opts },
      }
      for _, source in pairs(cmp.get_config().sources) do
        if source.name ~= "obsidian" and source.name ~= "obsidian_new" then
          table.insert(sources, source)
        end
      end
      cmp.setup.buffer { sources = sources }
    end

    vim.api.nvim_create_autocmd({ "BufRead" }, {
      group = group,
      pattern = tostring(self.dir / "**.md"),
      callback = cmp_setup,
    })
  end

  -- Add missing frontmatter on BufWritePre
  vim.api.nvim_create_autocmd({ "BufWritePre" }, {
    group = group,
    pattern = tostring(self.dir / "**.md"),
    callback = function(args)
      if is_template(args.match) then
        return
      end

      local bufnr = vim.api.nvim_get_current_buf()
      local note = obsidian.note.from_buffer(bufnr, self.dir)
      if not note:should_save_frontmatter() or self.opts.disable_frontmatter == true then
        return
      end

      local frontmatter = nil
      if self.opts.note_frontmatter_func ~= nil then
        frontmatter = self.opts.note_frontmatter_func(note)
      end
      local lines = note:frontmatter_lines(nil, frontmatter)
      vim.api.nvim_buf_set_lines(bufnr, 0, note.frontmatter_end_line and note.frontmatter_end_line or 0, false, lines)
      echo.info("Updated frontmatter", self.opts.log_level)
    end,
  })

  return self
end

---Find the path to the actual Obsidian vault (it may be in a parent of 'self.dir').
---
---@return string|?
client.vault = function(self)
  local vault_indicator_folder = ".obsidian"
  local dirs = self.dir:parents()
  table.insert(dirs, 0, self.dir:absolute())
  for _, dir in pairs(dirs) do
    ---@type Path
    ---@diagnostic disable-next-line: assign-type-mismatch
    local maybe_vault = Path:new(dir) / vault_indicator_folder
    if maybe_vault:is_dir() then
      return dir
    end
  end
  return nil
end

client._search_iter = function(self, search, search_opts)
  search_opts = search_opts and (search_opts .. " ") or ""
  local search_results = obsidian.util.search(self.dir, search, search_opts .. "-m 1")
  local find_results = obsidian.util.find(self.dir, search, self.opts.sort_by, self.opts.sort_reversed)

  local found = {}

  return function()
    local content_match = search_results()
    if content_match ~= nil then
      local path = vim.fs.normalize(content_match.path.text)
      found[path] = true
      return path
    end

    -- keep looking until we get a new match that we haven't seen yet.
    while true do
      local path_match = find_results()
      if path_match ~= nil then
        local path = vim.fs.normalize(path_match)
        if not found[path] then
          found[path] = true
          return path
        end
      else
        return nil
      end
    end
  end
end

---Search for notes. Returns an iterator over matching notes.
---
---@param search string
---@param search_opts string|?
---@return function
client.search = function(self, search, search_opts)
  local next_path = self:_search_iter(search, search_opts)

  ---@return obsidian.Note|?
  return function()
    local path = next_path()
    if path ~= nil then
      return obsidian.note.from_file(path, self.dir)
    else
      return nil
    end
  end
end

---An async version of `search` that runs the callback with an array of all matching notes.
---@param search string
---@param search_opts string|?
---@param callback function
client.search_async = function(self, search, search_opts, callback)
  local next_path = self:_search_iter(search, search_opts)
  local executor = require("obsidian.async").AsyncExecutor.new()

  local function task_fn(path, dir)
    local Note = require "obsidian.note"
    return Note.from_file_async(path, dir)
  end

  local function task_gen()
    local path = next_path()
    if path ~= nil then
      return path, tostring(self.dir)
    else
      return nil
    end
  end

  executor:map(task_fn, callback, task_gen)
end

---Create a new Zettel ID
---
---@param title string|?
---@return string
client.new_note_id = function(self, title)
  local today_id = tostring(os.date "%Y-%m-%d")
  if
    title ~= nil
    and string.len(title) >= 5
    and string.find(today_id, title, 1, true) == 1
    and not self:daily_note_path(today_id):is_file()
  then
    return today_id
  elseif self.opts.note_id_func ~= nil then
    local new_id = self.opts.note_id_func(title)
    -- Remote '.md' suffix if it's there (we add that later).
    new_id = new_id:gsub("%.md$", "", 1)
    return new_id
  else
    return obsidian.util.zettel_id()
  end
end

---Parse the title, ID, and path for a new note.
---
---@param title string|?
---@param id string|?
---@param dir string|Path|?
---
---@return string|?,string,Path
client.parse_title_id_path = function(self, title, id, dir)
  ---@type Path
  local base_dir = dir == nil and Path:new(self.dir) or Path:new(dir)
  local title_is_path = false

  -- Clean up title and guess the right base_dir.
  if title ~= nil then
    -- Trim whitespace.
    title = title:match "^%s*(.-)%s*$"

    if title:match "%.md" then
      -- Remove suffix.
      title = title:sub(1, title:len() - 3)
      title_is_path = true
    end

    -- Pull out any parent dirs from title.
    local parts = vim.split(title, Path.path.sep)
    if #parts > 1 then
      -- 'title' will just be the final part of the path.
      title = parts[#parts]
      -- Add the other parts to the base_dir.
      base_dir = base_dir / table.concat(parts, Path.path.sep, 1, #parts - 1)
    elseif dir == nil and self.opts.notes_subdir ~= nil then
      base_dir = base_dir / self.opts.notes_subdir
    end
  elseif dir == nil and self.opts.notes_subdir ~= nil then
    base_dir = base_dir / self.opts.notes_subdir
  end

  if title == "" then
    title = nil
  end

  -- Generate new ID if needed.
  local new_id = id and id or (title_is_path and title or self:new_note_id(title))

  -- Get path.
  ---@type Path
  ---@diagnostic disable-next-line: assign-type-mismatch
  local path = base_dir / (new_id .. ".md")

  return title, new_id, path
end

---Create and save a new note.
---
---@param title string|?
---@param id string|?
---@param dir string|Path|?
---@param aliases string[]|?
---
---@return obsidian.Note
client.new_note = function(self, title, id, dir, aliases)
  local new_title, new_id, path = self:parse_title_id_path(title, id, dir)

  if new_id == tostring(os.date "%Y-%m-%d") then
    return self:today()
  end

  -- Add title as an alias.
  ---@type string[]
  ---@diagnostic disable-next-line: assign-type-mismatch
  aliases = aliases == nil and {} or aliases
  if new_title ~= nil and new_title:len() > 0 and not obsidian.util.contains(aliases, new_title) then
    aliases[#aliases + 1] = new_title
  end

  -- Create Note object and save.
  local note = obsidian.note.new(new_id, aliases, {}, path)
  local frontmatter = nil
  if self.opts.note_frontmatter_func ~= nil then
    frontmatter = self.opts.note_frontmatter_func(note)
  end
  note:save(nil, not self.opts.disable_frontmatter, frontmatter)
  echo.info("Created note " .. tostring(note.id) .. " at " .. tostring(note.path), self.opts.log_level)

  return note
end

---Get the path to a daily note.
---
---@param id string
---@return Path
client.daily_note_path = function(self, id)
  ---@type Path
  local path = Path:new(self.dir)

  if self.opts.daily_notes.folder ~= nil then
    ---@type Path
    ---@diagnostic disable-next-line: assign-type-mismatch
    path = path / self.opts.daily_notes.folder
  elseif self.opts.notes_subdir ~= nil then
    ---@type Path
    ---@diagnostic disable-next-line: assign-type-mismatch
    path = path / self.opts.notes_subdir
  end
  ---@type Path
  ---@diagnostic disable-next-line: assign-type-mismatch
  path = path / (id .. ".md")
  return path
end

---Open (or create) the daily note.
---
---@param self obsidian.Client
---@param datetime integer
---@return obsidian.Note
client._daily = function(self, datetime)
  local id
  if self.opts.daily_notes.date_format ~= nil then
    id = tostring(os.date(self.opts.daily_notes.date_format, datetime))
  else
    id = tostring(os.date("%Y-%m-%d", datetime))
  end

  local path = self:daily_note_path(id)

  local alias
  if self.opts.daily_notes.alias_format ~= nil then
    alias = tostring(os.date(self.opts.daily_notes.alias_format, datetime))
  else
    alias = tostring(os.date("%B %-d, %Y", datetime))
  end

  -- Create Note object and save if it doesn't already exist.
  local note = obsidian.note.new(id, { alias }, { "daily-notes" }, path)
  if not note:exists() then
    if self.opts.daily_notes.template then
      obsidian.util.clone_template(self.opts.daily_notes.template, tostring(path), self, note:display_name())
    end
    local frontmatter = nil
    if self.opts.note_frontmatter_func ~= nil then
      frontmatter = self.opts.note_frontmatter_func(note)
    end
    note:save(nil, not self.opts.disable_frontmatter, frontmatter)
    echo.info("Created note " .. tostring(note.id) .. " at " .. tostring(note.path), self.opts.log_level)
  end

  return note
end

---Open (or create) the daily note for today.
---
---@return obsidian.Note
client.today = function(self)
  return self:_daily(os.time())
end

---Open (or create) the daily note from the last weekday.
---
---@return obsidian.Note
client.yesterday = function(self)
  return self:_daily(obsidian.util.working_day_before(os.time()))
end

---Resolve the query to a single note.
---
---@param query string
---@return obsidian.Note|?
client.resolve_note = function(self, query)
  -- Autocompletion for command args will have this format.
  local note_path, count = string.gsub(query, "^.*  ", "")
  if count > 0 then
    ---@type Path
    ---@diagnostic disable-next-line: assign-type-mismatch
    local full_path = self.dir / note_path
    return obsidian.note.from_file(full_path, self.dir)
  end

  -- Query might be a path.
  local paths_to_check = { Path:new(query), self.dir / query }
  if self.opts.notes_subdir ~= nil then
    table.insert(paths_to_check, self.dir / self.opts.notes_subdir / query)
  end
  if self.opts.daily_notes.folder ~= nil then
    table.insert(paths_to_check, self.dir / self.opts.daily_notes.folder / query)
  end
  for _, path in pairs(paths_to_check) do
    if path:is_file() then
      local ok, note = pcall(obsidian.note.from_file, path)
      if ok then
        return note
      end
    end
  end

  local query_lwr = string.lower(query)
  local maybe_matches = {}
  for note in self:search(query, "--ignore-case") do
    if query == note.id or query == note:display_name() or obsidian.util.contains(note.aliases, query) then
      -- Exact match! We're done!
      return note
    end

    for _, alias in pairs(note.aliases) do
      if query_lwr == string.lower(alias) then
        -- Lower case match, save this one for later.
        table.insert(maybe_matches, note)
        break
      end
    end
  end

  if #maybe_matches > 0 then
    return maybe_matches[1]
  end

  return nil
end

client._run_with_finder_backend = function(self, command_name, implementations)
  local finders_order = { "telescope.nvim", "fzf-lua", "fzf.vim" }
  if self.opts.finder then
    for idx, finder in ipairs(finders_order) do
      if finder == self.opts.finder then
        table.remove(finders_order, idx)
        break
      end
    end
    table.insert(finders_order, 1, self.opts.finder)
  end
  local success, err = pcall(obsidian.util.run_first_supported, command_name, finders_order, implementations)
  if not success then
    if type(err) == "string" then
      echo.err(err, client.opts.log_level)
    else
      error(err)
    end
  end
end

return obsidian
