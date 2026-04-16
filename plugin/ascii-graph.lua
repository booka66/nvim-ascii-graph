if vim.g.loaded_ascii_graph then return end
vim.g.loaded_ascii_graph = true

vim.api.nvim_create_user_command("AsciiGraph", function()
  require("ascii-graph").toggle()
end, {})
