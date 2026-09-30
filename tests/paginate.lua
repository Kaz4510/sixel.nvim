-- Run: nvim -l tests/paginate.lua
vim.opt.rtp:prepend(".")
local s = require("sixel")
local h = { 1, 1, 5, 1, 12, 1 } -- item heights; 12 is taller than the page
assert(s.page_end(h, 1, 8) == 4)                -- 1+1+5+1 = 8 fits exactly
assert(s.page_end(h, 5, 8) == 5)                -- oversized item gets a page to itself
assert(s.page_end(h, 6, 8) == 6)                -- last partial page
assert(s.page_start_before(h, 4, 8) == 1)       -- previous page fills backwards
assert(s.page_start_before(h, 5, 8) == 5)       -- oversized item alone going back too
assert(s.page_start_before(h, 3, 6) == 2)       -- 5+1 fits, adding the first item would not
print("paginate ok")
