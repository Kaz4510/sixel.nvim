-- :SixelRead opens the paged image reader on the current buffer.
vim.api.nvim_create_user_command("SixelRead", function()
    require("sixel").open()
end, { desc = "Read the current markdown buffer page by page with sixel images" })

-- :SixelRefresh drops the encode cache, re-downloads URL images and redraws the open page.
vim.api.nvim_create_user_command("SixelRefresh", function()
    require("sixel").refresh()
end, { desc = "Re-encode, re-download and repaint sixel images" })
