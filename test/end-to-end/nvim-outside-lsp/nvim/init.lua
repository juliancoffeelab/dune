vim.o.swapfile = false
vim.o.hidden = true
vim.o.termguicolors = false

vim.cmd("filetype plugin indent on")
vim.cmd("syntax off")

package.path = table.concat({
  vim.fn.stdpath("config") .. "/lua/?.lua",
  vim.fn.stdpath("config") .. "/lua/?/init.lua",
  package.path,
}, ";")

local smoke = require("nvim_outside_lsp")
smoke.setup()
