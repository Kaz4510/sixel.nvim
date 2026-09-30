local encode = require("sixel.encode")
local M = {}

M.config = {
    cell = { w = 10, h = 20}, -- pixel size of one terminal cell
    max_rows = 15, --tallest image in rows (also capped by the screen height)
    max_cols = 80, -- widest image in columns (clamped to the screen width)
    urls = true, -- download http(s) image links into the cache and render them
}

M.enabled = false -- set by setup() inside Windows Terminal with an encoder available

-- Step 1: scan. Lines like ![alt](path-or-url) plus ```mermaid fenced blocks
-- (`from` = opening fence, `lnum` = closing fence). Local paths must exist on disk.
local function scan(buf)
    local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(buf))
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local found = {}
    local fence -- lnum of an open ```mermaid fence
    for lnum, line in ipairs(lines) do
        if fence then
            if line:match("^%s*```") then
                found[#found + 1] = { from = fence, lnum = lnum, mermaid = table.concat(lines, "\n", fence + 1, lnum - 1) }
                fence = nil
            end
        elseif line:match("^%s*```%s*mermaid%s*$") then
            fence = lnum
        else
            local alt, dest = line:match("!%[(.-)%]%(%s*(.-)%s*%)")
            if dest and dest ~= "" then
                local cols = tonumber(alt:match("|(%d+)$"))
                -- Destination forms: <path with spaces>, path "title", path%20with%20spaces.
                local rel = dest:match("^<(.-)>")
                if not rel then
                    local t = dest:find('%s+"') or dest:find("%s+'") -- optional title after the path
                    rel = t and dest:sub(1, t - 1) or dest
                end
                if not rel:match("^https?://") then
                    rel = rel:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
                end
                if rel:match("^https?://") then
                    if M.config.urls then
                        found[#found + 1] = { lnum = lnum, url = rel, cols = cols }
                    end
                else
                    if not (rel:match("^/") or rel:match("^%a:")) then
                        rel = vim.fs.joinpath(dir, rel)
                    end
                    local path = vim.fs.normalize(rel)
                    if vim.uv.fs_stat(path) then
                        found[#found + 1] = { lnum = lnum, path = path, cols = cols }
                    end
                end
            end
        end
    end
    return lines, found
end

-- Cache directory for rendered diagrams and downloaded images.
local function cache_path(name)
    local dir = vim.fn.stdpath("cache") .. "/sixel"
    vim.fn.mkdir(dir, "p")
    return dir .. "/" .. name
end

-- Step 2b: render a ```mermaid block to a PNG with mermaid-cli, cached by content hash.
-- Needs `mmdc` (installed on the WSL side only); elsewhere the block stays as text.
local function mermaid_png(source, cb)
    local png = cache_path(vim.fn.sha256(source) .. ".png")
    if vim.uv.fs_stat(png) then
        return cb(png)
    end
    if vim.fn.executable("mmdc") == 0 then
        return cb(nil)
    end
    local mmd = png:gsub("%.png$", ".mmd")
    vim.fn.writefile(vim.split(source, "\n"), mmd)
    local bg = ("#%06x"):format(vim.api.nvim_get_hl(0, { name = "Normal" }).bg or 0)
    local theme = vim.o.background == "dark" and "dark" or "default"
    vim.system({ "mmdc", "-q", "-i", mmd, "-o", png, "-t", theme, "-b", bg }, {}, function(res)
        vim.schedule(function() cb(res.code == 0 and png or nil) end)
    end)
end

-- Step 2c: download an http(s) image into the cache, named by the hash of the URL. The
-- encoders sniff the format from the bytes, so no extension is needed. `force` re-downloads.
local function fetch_image(url, force, cb)
    local file = cache_path(vim.fn.sha256(url))
    if force then
        os.remove(file)
    end
    if vim.uv.fs_stat(file) then
        return cb(file)
    end
    vim.system({ "curl", "-sfL", "--max-time", "10", "-o", file, url }, {}, function(res)
        if res.code ~= 0 then
            os.remove(file) -- never cache a failed download
        end
        vim.schedule(function() cb(res.code == 0 and file or nil) end)
    end)
end

-- Step 3: paginate. heights[i] is the screen rows item i needs. A page is the longest
-- run of items that fits in `h` rows, and always holds at least one item.
function M.page_end(heights, start, h)
    local used, i = 0, start
    while i <= #heights and used + heights[i] <= h do
        used = used + heights[i]
        i = i + 1
    end
    return math.max(i - 1, start)
end

-- The start of the page that ends at `stop`, filling backwards (used for "previous page").
function M.page_start_before(heights, stop, h)
    local used, i = 0, stop
    while i >= 1 and used + heights[i] <= h do
        used = used + heights[i]
        i = i - 1
    end
    return math.min(i + 1, stop)
end

-- The reader: a full-screen float over the editor showing one page at a time.
-- R = { src, win, buf, h, cols, items, heights, start, stop, gen }
local R
local gen = 0

local function screen_size()
    return vim.o.columns, vim.o.lines - vim.o.cmdheight
end

-- Rows a text line takes with 'wrap' on and 'linebreak' off.
local function text_rows(line, cols)
    return math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / cols))
end

-- Step 4: show the page starting at item R.start. Its lines go into the buffer with a real
-- blank line per image row; the page fits the window, so nothing ever scrolls. Then clear
-- the terminal and paint every image of the page in one write.
local function show()
    R.stop = M.page_end(R.heights, R.start, R.h)
    local lines, images = {}, {}
    for i = R.start, R.stop do
        local item = R.items[i]
        vim.list_extend(lines, item.lines)
        if item.entry then
            images[#images + 1] = { lnum = #lines + 1, entry = item.entry }
            for _ = 1, item.entry.rows do
                lines[#lines + 1] = ""
            end
        end
    end
    vim.bo[R.buf].modifiable = true
    vim.api.nvim_buf_set_lines(R.buf, 0, -1, false, lines)
    vim.bo[R.buf].modifiable = false
    vim.api.nvim_win_set_cursor(R.win, { 1, 0 })
    vim.cmd.mode() -- ESC[2J: the only clear Windows Terminal treats as erasing images
    vim.cmd.redraw()
    local out = {}
    for _, img in ipairs(images) do
        local row = vim.fn.screenpos(R.win, img.lnum, 1).row -- 0 when not visible
        if row > 0 and row + img.entry.rows - 1 <= R.h then
            out[#out + 1] = ("\27[%d;1H%s"):format(row, img.entry.data)
        end
    end
    if #out > 0 then
        vim.api.nvim_ui_send("\0277" .. table.concat(out) .. "\0278")
    end
    vim.api.nvim_echo({ { ("sixel: lines %d-%d of %d"):format(R.items[R.start].src,
        R.items[R.stop].last, R.items[#R.items].last) } }, false, {})
end

local function set_lines(text)
    vim.bo[R.buf].modifiable = true
    vim.api.nvim_buf_set_lines(R.buf, 0, -1, false, text)
    vim.bo[R.buf].modifiable = false
end

-- Step 2: encode every image of the source for the current screen size, then cut the
-- source into items (one text line, one image line, or one mermaid block) and show the
-- page holding source line `lnum`.
-- ponytail: encodes the whole document before the first page; encode per page if big
-- documents make the first open too slow (the encode cache makes later opens instant).
local function build(lnum, force)
    gen = gen + 1
    local my_gen = gen
    R.cols, R.h = screen_size()
    vim.api.nvim_win_set_config(R.win, { relative = "editor", row = 0, col = 0, width = R.cols, height = R.h })
    local cfg = M.config
    local lines, found = scan(R.src)
    local pending = #found
    set_lines({ ("encoding %d images..."):format(pending) })

    local function done()
        if my_gen ~= gen or not R then
            return
        end
        local by_line = {}
        for _, img in ipairs(found) do
            by_line[img.from or img.lnum] = img
        end
        local items, heights = {}, {}
        local l = 1
        while l <= #lines do
            local img = by_line[l]
            local item
            if img and img.mermaid and img.entry then
                item = { src = l, last = img.lnum, lines = {}, entry = img.entry } -- the diagram replaces the block
            else
                item = { src = l, last = l, lines = { lines[l] }, entry = img and not img.mermaid and img.entry or nil }
            end
            local rows = item.entry and item.entry.rows or 0
            for _, t in ipairs(item.lines) do
                rows = rows + text_rows(t, R.cols)
            end
            items[#items + 1], heights[#heights + 1] = item, rows
            l = item.last + 1
        end
        if #items == 0 then
            items[1], heights[1] = { src = 1, last = 1, lines = { "" } }, 1
        end
        R.items, R.heights, R.start = items, heights, 1
        for i, item in ipairs(items) do
            if item.src <= lnum then
                R.start = i
            end
        end
        show()
    end

    if pending == 0 then
        return done()
    end
    -- Leave one row for the image's own link line.
    local max_h = math.max(1, math.min(cfg.max_rows, R.h - 1)) * cfg.cell.h
    for _, img in ipairs(found) do
        local max_w = math.min(img.cols or cfg.max_cols, R.cols) * cfg.cell.w
        local function finish(entry)
            img.entry = entry
            pending = pending - 1
            if pending == 0 then
                done()
            end
        end
        local function encode_path(path)
            if not path or my_gen ~= gen then
                return finish(nil)
            end
            encode.encode(path, max_w, max_h, cfg.cell, finish)
        end
        if img.mermaid then
            mermaid_png(img.mermaid, encode_path)
        elseif img.url then
            fetch_image(img.url, force, encode_path)
        else
            encode_path(img.path)
        end
    end
end

function M.next_page()
    if R and R.items and R.stop < #R.items then
        R.start = R.stop + 1
        show()
    end
end

function M.prev_page()
    if R and R.items and R.start > 1 then
        R.start = M.page_start_before(R.heights, R.start - 1, R.h)
        show()
    end
end

-- Close the reader and put the source cursor on the first line of the page being read.
function M.close()
    if not R then
        return
    end
    local r = R
    R = nil
    gen = gen + 1 -- drop pending encodes
    if r.items and vim.api.nvim_win_is_valid(r.src_win) then
        vim.api.nvim_win_set_cursor(r.src_win, { r.items[r.start].src, 0 })
    end
    if vim.api.nvim_win_is_valid(r.win) then
        vim.api.nvim_win_close(r.win, true)
    end
    vim.schedule(function() vim.cmd.mode() end) -- erase the page's pixels
end

-- Open the reader on the current buffer, starting at the cursor line.
function M.open()
    if not M.enabled then
        return vim.notify("sixel: needs Windows Terminal and an encoder (see README)", vim.log.levels.WARN)
    end
    if R then
        return
    end
    local src_win = vim.api.nvim_get_current_win()
    local lnum = vim.api.nvim_win_get_cursor(src_win)[1]
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].syntax = "markdown" -- highlighting without filetype plugins such as render-markdown
    local cols, h = screen_size()
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor", row = 0, col = 0, width = cols, height = h, style = "minimal", zindex = 200,
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = false -- text_rows() assumes plain character wrapping
    vim.wo[win].breakindent = false
    vim.wo[win].conceallevel = 0 -- the float copies the source window's (render-markdown sets it)
    vim.wo[win].showbreak = "NONE"
    R = { src = vim.api.nvim_win_get_buf(src_win), src_win = src_win, win = win, buf = buf }

    local function map(keys, fn)
        for _, k in ipairs(keys) do
            vim.keymap.set("n", k, fn, { buffer = buf, nowait = true })
        end
    end
    map({ "n", "<Space>", "<PageDown>" }, M.next_page)
    map({ "p", "<BS>", "<PageUp>" }, M.prev_page)
    map({ "q", "<Esc>" }, M.close)

    local group = vim.api.nvim_create_augroup("sixel_reader", { clear = true })
    vim.api.nvim_create_autocmd("VimResized", { group = group, callback = function()
        if R and R.items then
            build(R.items[R.start].src)
        end
    end })
    vim.api.nvim_create_autocmd("CmdlineLeave", { group = group, callback = function()
        vim.schedule(function()
            -- `:q` in the reader wipes its buffer before this runs.
            if R and R.items and vim.api.nvim_buf_is_valid(R.buf) then
                show()
            end
        end)
    end })
    vim.api.nvim_create_autocmd("WinLeave", { group = group, buffer = buf, callback = function()
        vim.schedule(M.close)
    end })
    vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = buf, callback = function()
        vim.api.nvim_del_augroup_by_id(group)
        if R then
            vim.schedule(M.close)
        end
    end })
    build(lnum)
end

-- :SixelRefresh: re-encode, re-download URL images and redraw the open page.
function M.refresh()
    encode.clear()
    if R and R.items then
        build(R.items[R.start].src, true)
    end
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    local encoder = vim.fn.has("win32") == 1 and "pwsh" or "convert"
    -- Outside Windows Terminal or without an encoder, :SixelRead just warns.
    M.enabled = vim.env.WT_SESSION ~= nil and vim.fn.executable(encoder) == 1
end

return M
