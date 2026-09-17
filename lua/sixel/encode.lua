-- Turn an image file into a sixe. string plus its footprint in cells.
-- Pure: no terminal writes,  no autocmds. Results are cached per path and size.
--

local M = {}

local cache = {} -- key: path .. "|" .. max_w .. "x" .. max_h

-- Encoder command for this OS. Both print sixel on stdout, keep the aspect
-- ratio, and for inside a max_w x max_h pixel box.
--

local function command(path, max_w, max_h)
    if vim.fn.has("win32") == 1 then
        -- ConvertTo-Sixel sizes in *its* cells, and with stdout piped it always
        -- assumes 10x20 px cells, so convert the pixel budget into those units.
        -- System.Drawing reads the native size first, so small images are never
        -- scaled up: the budget becomes min(budget, native).
        local p = path:gsub("'", "''")
        local ps = ("Add-Type -AssemblyName System.Drawing; "
            .. "$i = [System.Drawing.Image]::FromFile('%s'); "
            .. "$w = [math]::Min(%d, $i.Width); $h = [math]::Min(%d, $i.Height); $i.Dispose(); "
            .. "ConvertTo-Sixel -Path '%s' -Width ([math]::Max(1, [math]::Floor($w / 10))) "
            .. "-Height ([math]::Max(1, [math]::Ceiling($h / 20))) -Force"):format(p, max_w, max_h, p)
        return { "pwsh", "-NoProfile", "-NonInteractive", "-Command", ps }
    end
    -- ImageMagick: the trailing ">" means "only shrink", never enlarge.
    return { "convert", path, "-resize", ("%dx%d>"):format(max_w, max_h), "sixel:-" }
end

-- Asynchronous. cb receives {data, cols, rows } or nul when encoding fails.
function M.encode(path, max_w, max_h, cell, cb)
    local key = path .. "|" .. max_w .. "x" .. max_h
    if cache[key] then
        return cb(cache[key])
    end
    vim.system(command(path, max_w, max_h), {}, function(res)
        local data = res.stdout or ""
        local w, h = data:match('"1;1;(%d+);(%d+)')
        local entry = nil
        if res.code == 0 and w then
            entry = {
                data = (data:gsub("%s+$", "")),
                cols = math.ceil(tonumber(w)/cell.w),
                rows = math.ceil(tonumber(h)/cell.h),
            }
            cache[key] = entry
        end
        vim.schedule(function() cb(entry) end)
    end)
end

function M.clear()
    cache = {}
end

return M

