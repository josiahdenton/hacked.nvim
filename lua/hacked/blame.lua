local M = {}

local tbl = require("hacked.tbl")
local buffer = require("hacked.buffer")
local str = require("hacked.str")

--- @class hacked.blame.Config

M.setup = function() end

--- @class hacked.blame.Parts
--- @field commit string
--- @field author string
--- @field date string
--- @field time string

--- @param blame string
--- @return hacked.blame.Parts
local parse_blame = function(blame)
    local commit = vim.split(blame, " ", { trimempty = true })[1]
    local author_datetime = vim.split(
        vim.split(blame, "(", { plain = true, trimempty = true })[2],
        ")",
        { plain = true, trimempty = true }
    )[1]
    local _start = string.find(author_datetime, "(%d+%-%d+%-%d+)")
    local author = string.sub(author_datetime, 1, _start - 1)
    local datetime = _start and string.sub(author_datetime, _start) or ""
    local datetime_parts = vim.split(datetime, " ", { trimempty = true })
    local date = #datetime_parts >= 2 and datetime_parts[1] or ""
    local time = #datetime_parts >= 2 and datetime_parts[2] or ""

    commit = string.gsub(commit, "%^", "") --- TODO: there may be more normalization changes I would need to do

    return {
        commit = commit,
        author = vim.trim(author),
        date = date,
        time = time,
    }
end

--- @param commit_sha string
--- @return string
local commit_message = function(commit_sha)
    local cmd = vim.system({ "git", "show", "-s", "--format=%B", commit_sha }, { text = true }):wait()
    if cmd.stdout then
        return vim.trim(cmd.stdout)
    end

    return ""
end

--- get the git blame for a line
local blame_win = -1

M.line = function()
    if vim.api.nvim_win_is_valid(blame_win) then
        vim.api.nvim_set_current_win(blame_win)
    end

    local rel_path = vim.fn.expand("%:.")
    local cur_pos = vim.fn.getpos(".")[2]
    local blame_bufnr = vim.api.nvim_create_buf(false, true)
    local cmd = vim.system({ "git", "blame", rel_path, string.format("-L %d,%d", cur_pos, cur_pos) }, { text = true })
        :wait()
    local blame
    if #cmd.stderr > 0 then
        if string.find(cmd.stderr, "no such path") then
            blame = {
                author = "Untracked File",
                date = "now",
                time = "",
                commit = "00000000",
            }
        end
    elseif #cmd.stdout > 0 then
        blame = parse_blame(cmd.stdout)
    end

    local commit_symbol = ""
    blame_win = vim.api.nvim_open_win(blame_bufnr, false, {
        title = "git blame",
        border = "rounded",
        relative = "cursor",
        row = 0,
        col = 2,
        height = 3,
        width = 55,
    })

    vim.keymap.set("n", "<enter>", function()
        vim.system({ "gh", "browse", blame.commit }):wait()
    end, { buffer = blame_bufnr, desc = "git blame: browse commit" })

    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = vim.api.nvim_get_current_buf(),
        callback = function()
            if vim.api.nvim_buf_is_valid(blame_bufnr) then
                vim.api.nvim_buf_delete(blame_bufnr, { force = true })
            end
        end,
    })

    local message = commit_message(blame.commit)
    local ns_id = vim.api.nvim_create_namespace("hacked.blame.hover")
    vim.api.nvim_buf_set_extmark(blame_bufnr, ns_id, 0, 0, {
        virt_text = {
            { " ", "TodoFgTODO" },
            { blame.author .. " ", "TodoFgTODO" },
            { blame.date .. " " .. blame.time, "Comment" },
        },
        virt_lines = {
            { { message, "Comment" } },
            { { commit_symbol .. " " .. blame.commit, "TodoFgTODO" } },
        },
        virt_text_pos = "overlay",
    })
end

--- @param blame string
--- @return table<hacked.blame.Parts>
local parse_blame_lines = function(blame)
    local lines = vim.split(blame, "\n", { trimempty = true })
    local blames = {}
    for _, line in ipairs(lines) do
        local _blame = parse_blame(line)
        table.insert(blames, _blame)
    end
    return blames
end

---@param bufnr integer
---@param sel_start integer
---@param sel_end integer
--- @return table<integer>
local offsets = function(bufnr, sel_start, sel_end)
    local lines = vim.api.nvim_buf_get_lines(bufnr, sel_start - 1, sel_end, false)
    local max_line_length = tbl.max(vim.iter(lines)
        :map(function(v)
            return str.utf8_len(v)
        end)
        :totable())

    return vim.iter(lines)
        :map(function(v)
            return max_line_length - str.utf8_len(v)
        end)
        :totable()
end

--- display git blame for a selction in a split window
M.selection = function()
    if vim.api.nvim_win_is_valid(blame_win) then
        vim.api.nvim_set_current_win(blame_win)
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local rel_path = vim.fn.expand("%:.")
    local sel_start, sel_end = buffer.active_selection()
    local cmd = vim.system({ "git", "blame", rel_path, string.format("-L %d,%d", sel_start, sel_end) }, { text = true })
        :wait()
    local blames
    if #cmd.stderr > 0 then
        if string.find(cmd.stderr, "no such path") then
            blames = tbl.rep({}, {
                author = "Untracked File",
                date = "now",
                time = "",
                commit = "00000000",
            }, sel_end - sel_start + 1)
        end
    elseif #cmd.stdout > 0 then
        blames = parse_blame_lines(cmd.stdout)
    end

    local blame_groups = tbl.group_by(blames, function(a, b)
        return a.commit == b.commit
    end)

    local ns = vim.api.nvim_create_namespace("hacked.blame.selection")
    vim.api.nvim_buf_clear_namespace(bufnr, ns, sel_start - 1, sel_end)
    local whitespace = offsets(bufnr, sel_start, sel_end)
    local line = 1
    for _, blame_group in ipairs(blame_groups) do
        for i, blame in ipairs(blame_group) do
            if i == 1 then
                vim.api.nvim_buf_set_extmark(bufnr, ns, sel_start - 2 + line, 0, {
                    virt_text = {
                        { string.rep(" ", whitespace[line]), "Comment" },
                        { " ", "TodoFgTODO" },
                        { blame.author .. " ", "TodoFgTODO" },
                        { blame.date .. " " .. blame.time .. " ", "Comment" },
                        { blame.commit, "TodoFgTODO" },
                    },
                    virt_text_pos = "eol",
                })
            else
                vim.api.nvim_buf_set_extmark(bufnr, ns, sel_start - 2 + line, 0, {
                    virt_text = {
                        { string.rep(" ", whitespace[line]), "Comment" },
                        { "│", "TodoFgTODO" },
                    },
                    virt_text_pos = "eol",
                })
            end
            line = line + 1
        end
    end

    -- TODO: move this to uv otherwise I can't reset the timer
    vim.defer_fn(function()
        vim.api.nvim_buf_clear_namespace(bufnr, ns, sel_start - 1, sel_end)
    end, 15 * 1000)
end

M.browse = function()
    local rel_path = vim.fn.expand("%:.")
    local cur_pos = vim.fn.getpos(".")[2]
    local cmd = vim.system({ "git", "blame", rel_path, string.format("-L %d,%d", cur_pos, cur_pos) }, { text = true })
        :wait()
    local blame
    if #cmd.stderr > 0 then
        vim.notify("no commit found", vim.log.levels.WARN, {})
    elseif #cmd.stdout > 0 then
        blame = parse_blame(cmd.stdout)
        vim.system({ "gh", "browse", blame.commit }, { detach = true })
    end
end

return M
