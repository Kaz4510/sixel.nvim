local encode = require("sixel.encode")
local M = {}

M.config = {
    cell = { w = 10, h = 20}, -- pixel size of one terminal cell
    max_rows = 15, --tallest image in rows
    max_cols = 80, -- widest image in columns (clamped to the window's width)
    debounce_ms = 150,
    urls = true, -- download http(s) image links into the cache and render them
}

local ns = vim.api.nvim_create_namespace("sixel")
local placements = {} -- placements[buf] = {{mark = extmark id, entry = {data, cols, rows } }, ... }
local generation = {} -- generation[buf] = counter; stale encode callbacks compare against it

local timer = vim.uv.new_timer()


-- Step 1: scan. Lines like ![alt](path-or-url) plus ```mermaid fenced blocks
-- (rendered below their closing fence). Local paths must exist on disk.
local function scan(buf)
    local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(buf))
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local found = {}
    local fence -- lnum of an open ```mermaid fence
    for lnum, line in ipairs(lines) do
        if fence then
            if line:match("^%s*```") then
                found[#found + 1] = { lnum = lnum, mermaid = table.concat(lines, "\n", fence + 1, lnum - 1) }
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
    return found
end


-- step 3: reserve. `rows` blank virtual lines under the line that owns 'mark' 
local function reserve(buf, mark, rows)
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
    if not pos[1] then
        return false
    end
    local blank = {}
    for _ = 1, rows do
        blank[#blank +1] = { { "" } }
    end
    vim.api.nvim_buf_set_extmark(buf, ns, pos[1], 0, { id = mark, virt_lines = blank })
    return true
end

local last_sig -- where images were painted last time; a change means old pixels may linger

-- Step 4: paint. Appends the escape string and the position of every fully visible image of `win`.
local function paint_win(win, out, sig)
    local buf = vim.api.nvim_win_get_buf(win)
    local list = placements[buf]
    if not list or #list == 0 then
        return
    end
    local info = vim.fn.getwininfo(win)[1]
    local col = info.wincol + info.textoff -- 1-based screen column of the text area
    local bottom = info.winrow + info.height - 1 -- last screen row inside the window
    for _, p in ipairs(list) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, p.mark, {})
        if pos[1] then
            local lnum = pos[1] + 1
            -- Screen row of the line's last wrapped row; the blank rows start right below.
            local len = #vim.api.nvim_buf_get_lines(buf, pos[1], lnum, false)[1]
            local row = vim.fn.screenpos(win, lnum, math.max(len, 1)).row -- 0 when not visible
            local first, last = row + 1, row + p.entry.rows
            if row > 0 and last <= bottom and last < vim.o.lines then
                out[#out + 1] = ("\27[%d;%dH%s"):format(first, col, p.entry.data)
                sig[#sig + 1] = ("%d:%d:%d:%d"):format(win, first, col, p.entry.rows)
            end
        end
    end
end

function M.paint()
    if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
        return -- images stay hidden while typing
    end
    vim.cmd.redraw() -- flush Neovim's own drawing first, so screenpos is current
    local out, sig = {}, {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        paint_win(win, out, sig)
    end
    local s = table.concat(sig, " ")
    if last_sig and s ~= last_sig then
        -- An image moved or left the screen. Rows that were blank both before and after a
        -- scroll are never repainted by Neovim, so stale pixels survive there; clear them.
        vim.cmd.mode() -- ESC[2J: the only clear Windows Terminal treats as erasing images
    end
    last_sig = s
    if #out > 0 then
        vim.api.nvim_ui_send("\0277" .. table.concat(out) .. "\0278")
    end
end

local function paint_soon()
    timer:stop()
    timer:start(M.config.debounce_ms, 0, vim.schedule_wrap(M.paint))
end

-- step 5: erase. A full redraw repaints the text and drops every pixel. 
local function erase(buf)
    if placements[buf] and #placements[buf] > 0 then
        vim.cmd.mode() -- ESC[2J: the only clear Windows Terminal treats as erasing images
    end
end



-- Cache directory for rendered diagrams and downloaded images.
local function cache_path(name)
    local dir = vim.fn.stdpath("cache") .. "/sixel"
    vim.fn.mkdir(dir, "p")
    return dir .. "/" .. name
end

-- Step 2b: render a ```mermaid block to a PNG with mermaid-cli, cached by content hash.
-- Needs `mmdc` (installed on the WSL side only); elsewhere the block is skipped.
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

-- Scan, produce a local file (render mermaid / download URLs), encode, reserve, then paint.
-- `force` re-downloads URL images (used by :SixelRefresh).
function M.refresh(buf, force)
    buf = buf or vim.api.nvim_get_current_buf()
    local win = vim.fn.bufwinid(buf)
    if win == -1 then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    placements[buf] = {}
    generation[buf] = (generation[buf] or 0) + 1
    local gen = generation[buf]

    local cfg = M.config
    local text_cols = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
    local max_h = cfg.max_rows * cfg.cell.h
    for _, img in ipairs(scan(buf)) do
        -- Place the mark now so it follows the line through edits while the encoder runs.
        local mark = vim.api.nvim_buf_set_extmark(buf, ns, img.lnum - 1, 0, {})
        local cols = math.min(img.cols or cfg.max_cols, text_cols)
        local max_w = cols * cfg.cell.w
        local function encode_path(path)
            if not path or generation[buf] ~= gen then
                return
            end
            encode.encode(path, max_w, max_h, cfg.cell, function(entry)
                if generation[buf] ~= gen or not entry or not vim.api.nvim_buf_is_valid(buf) then
                    return
                end
                if reserve(buf, mark, entry.rows) then
                    table.insert(placements[buf], { mark = mark, entry = entry })
                    paint_soon()
                end
            end)
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

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    local encoder = vim.fn.has("win32") == 1 and "pwsh" or "convert"
    if not vim.env.WT_SESSION or vim.fn.executable(encoder) == 0 then
        return -- not Windows Terminal, or no encoder: stay dormant (Kitty via wslg uses snacks)
    end
    local group = vim.api.nvim_create_augroup("sixel", { clear = true })
    local function on(events, pattern, callback)
        vim.api.nvim_create_autocmd(events, { group = group, pattern = pattern, callback = callback })
    end
    on({ "BufWinEnter", "InsertLeave", "TextChanged", "BufWritePost", "VimResized" }, "*.md", function(ev) M.refresh(ev.buf) end)
    on({ "InsertEnter", "BufWinLeave"}, "*.md", function(ev) erase(ev.buf) end)
    on({ "WinScrolled", "CursorHold"}, "*", paint_soon)
end

return M

