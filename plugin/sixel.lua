-- :SixelRefresh drops the encode cache, re-downloads URL images and repaints.
vim.api.nvim_create_user_command("SixelRefresh", function()
    require("sixel.encode").clear()
    require("sixel").refresh(nil, true)
end, { desc = "Re-encode, re-download and repaint sixel images" })
