-- Useful type definitions go here.

---@class CommandArgs
---The table passed to user commands.
---For details see `:help nvim_create_user_command()` and the command attribute docs
---
---@field name string Command name
---@field args string The args passed to the command, if any <args>
---@field fargs table The args split by unescaped whitespace (when more than one argument is allowed), if any <f-args>
---@field nargs string Number of arguments |:command-nargs|
---@field bang boolean "true" if the command was executed with a ! modifier <bang>
---@field line1 number The starting line of the command range <line1>
---@field line2 number The final line of the command range <line2>
---@field range number The number of items in the command range: 0, 1, or 2 <range>
---@field count number Any count supplied <count>
---@field reg string The optional register, if specified <reg>
---@field mods string Command modifiers, if any <mods>
---@field smods table Command modifiers in a structured format. Has the same structure as the "mods" key of
