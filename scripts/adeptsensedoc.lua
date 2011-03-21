-- Copyright 2007-2011 Mitchell mitchell<att>caladbolg.net. See LICENSE.

---
-- Adeptsense doclet for LuaDoc.
-- This module is used by LuaDoc to create an adeptsense for Lua with a fake
-- ctags file and an api file.
-- Since LuaDoc does not recognize module fields, this doclet parses the Lua
-- modules for comments of the form "-- * `field_name`" to generate a field tag
-- and apidoc. Multiple line comments for fields must be indented flush with
-- `field_name` (3 spaces). Indenting more than this preserves formatting in the
-- apidoc.
-- @usage luadoc -d [output_path] -doclet path/to/adeptsensedoc [file(s)]
module('adeptsensedoc', package.seeall)

local CTAGS_FMT = '%s\t_\t0;"\t%s\t%s'
local string_format = string.format

-- Writes a ctag.
-- @param file The file to write to.
-- @param name The name of the tag.
-- @param k The kind of ctag. Lua adeptsense uses 4 kinds: m Module, f Function,
--   t Table, and F Field.
-- @param ext_fields The ext_fields for the ctag.
local function write_tag(file, name, k, ext_fields)
  if type(ext_fields) == 'table' then
    ext_fields = table.concat(ext_fields, '\t')
  end
  file[#file + 1] = string_format(CTAGS_FMT, name, k, ext_fields)
end

-- Writes a function or field apidoc.
-- @param file The file to write to.
-- @param m The LuaDoc module object.
-- @param f The LuaDoc function object.
local function write_apidoc(file, m, f)
  -- Function or field name.
  local name = f.name
  if not name:find('[%.:]') then name = m.name..'.'..name end
  -- Block documentation for the function or field.
  local doc = { 'fmt -s -w 80 <<"EOF"' }
  -- Function arguments.
  local args = f.param and '('..table.concat(f.param, ', ')..')' or ''
  doc[#doc + 1] = name..args
  -- Function or field description.
  doc[#doc + 1] = f.description:gsub('\\n', '\\\\n')
  -- Function parameters (@param).
  if f.param then
    for _, p in ipairs(f.param) do
      if f.param[p] and #f.param[p] > 0 then
        doc[#doc + 1] = '@param '..f.param[p]:gsub('\\n', '\\\\n')
      end
    end
  end
  -- Function usage (@usage).
  if f.usage then
    if type(f.usage) == 'string' then
      doc[#doc + 1] = '@usage '..f.usage
    else
      for _, u in ipairs(f.usage) do doc[#doc + 1] = '@usage '..u end
    end
  end
  -- Function returns (@return).
  if f.ret then doc[#doc + 1] = '@return '..f.ret end
  -- See also (@see).
  if f.see then
    if type(f.see) == 'string' then
      doc[#doc + 1] = '@see '..f.see
    else
      for _, s in ipairs(f.see) do doc[#doc + 1] = '@see '..s end
    end
  end
  -- Format the block documentation.
  doc[#doc + 1] = 'EOF'
  local p = io.popen(table.concat(doc, '\n'))
  doc = p:read('*all'):gsub('\n', '\\n')
  p:close()
  file[#file + 1] = table.concat({ name:match('[^%.:]+$') , doc }, ' ')
end

-- Called by LuaDoc to process a doc object.
-- @param doc The LuaDoc doc object.
function start(doc)
--  require 'luarocks.require'
--  local profiler = require 'profiler'
--  profiler.start()

  local modules = doc.modules

  -- Convert module functions in the Lua luadoc into LuaDoc modules.
  local lua_luadoc = doc.files['../modules/lua/lua.luadoc']
  if lua_luadoc then
    for _, f in ipairs(lua_luadoc.functions) do
      f = lua_luadoc.functions[f]
      local module = f.name:match('^([^%.]+)%.') or '_G'
      if not modules[module] then
        modules[#modules + 1] = module
        modules[module] = { name = module, functions = {} }
      end
      local module = modules[module]
      module.functions[#module.functions + 1] = f.name
      module.functions[f.name] = f
    end
  end

  -- Parse out module fields (-- * `FIELD`: doc) and insert them into the
  -- module's LuaDoc.
  for _, file in ipairs(doc.files) do
    local module, field, docs
    -- Adds the field to its module's LuaDoc.
    local function add_field()
      local doc = table.concat(docs, ' ')
      doc = doc:gsub('\n ', '\n'):gsub('<br />', '')
      doc = doc:gsub('%[([^%]]+)%]%b[]', '%1'):gsub('%[([^%]]+)%]%b()', '%1')
      field.description = doc
      local m = modules[field.module]
      if not m.fields then m.fields = {} end
      m.fields[#m.fields + 1] = field.name
      m.fields[field.name] = field
      field = nil
    end
    local f = io.open(file, 'rb')
    for line in f:lines() do
      if not field and line:find('^module%(') then
        -- Get the module's name to add the parsed fields to.
        module = line:match("^module%('([^']+)'")
      elseif line:find('^%-%- %* `') then
        -- New field; if another field was parsed right before this one, add
        -- the former field to its module's LuaDoc.
        if field then add_field() end
        field, docs = {}, {}
        local name, doc = line:match('^%-%- %* `([^`]+)`([^\r\n]*)')
        field.module = module or name:match('^[^%.]+')
        field.name = name:match('[^%.]+$')
        if doc ~= '' then doc = doc:sub(3) end -- ignore ': ' at beginning
        docs[#docs + 1] = doc
      elseif field and line:find('^%-%-%s+([^\r\n]+)') then
        -- Add this additional documentation to the current field being
        -- parsed. If the doc is indented more than usual, preserve the
        -- formatting by adding a newline to the previous doc line.
        local doc, indent = line:match('^%-%-%s%s%s((%s*)[^\r\n]+)')
        if #indent > 0 and docs[#docs]:sub(-1) ~= '\n' then
          docs[#docs] = docs[#docs]..'\n'
        end
        docs[#docs + 1] = #indent > 0 and doc..'\n' or doc
      elseif field and
             (line:find('^%-%-[\r\n]*$') or line:find('^[\r\n]*$')) then
        -- End of field documentation. Add it to its module's LuaDoc.
        add_field()
      end
    end
    f:close()
  end

  -- Process LuaDoc and write the ctags and api file.
  local ctags, apidoc = {}, {}
  for _, m in ipairs(modules) do
    m = modules[m]
    local module = m.name
    -- Tag the module.
    write_tag(ctags, module, 'm', '')
    if module:find('%.') then
      -- Tag the last part of the module as a table of the first part.
      local parent, child = module:match('^(.-)%.([^%.]+)$')
      write_tag(ctags, child, 't', 'class:'..parent)
    elseif module ~= '_G' then
      -- Tag the module as a global table.
      write_tag(ctags, module, 't', 'class:_G')
      write_tag(ctags, module, 't', '')
    end
    -- Tag the functions and write the apidoc.
    for _, f in ipairs(m.functions) do
      if not f:find('no_functions') then -- ignore placeholders
        local func = f:match('[^%.:]+$')
        write_tag(ctags, func, 'f', 'class:'..module)
        if module == '_G' then write_tag(ctags, func, 'f', '') end -- global
        write_apidoc(apidoc, m, m.functions[f])
      end
    end
    -- Tag the tables.
    for _, t in ipairs(m.tables or {}) do
      write_tag(ctags, t, 't', 'class:'..module)
      if module == '_G' then write_tag(ctags, t, 't', '') end -- global
    end
    -- Tag the fields.
    for _, f in ipairs(m.fields or {}) do
      write_tag(ctags, f, 'F', 'class:'..module)
      if module == '_G' then write_tag(ctags, f, 'F', '') end -- global
      write_apidoc(apidoc, m, m.fields[f])
    end
  end
  local f = io.open(options.output_dir..'/tags', 'w')
  f:write(table.concat(ctags, '\n'))
  f:close()
  f = io.open(options.output_dir..'api', 'w')
  f:write(table.concat(apidoc, '\n'))
  f:close()

--  profiler.stop()
end

return _M