local prompts = require("gen.prompts")
local M = {}

local curr_buffer = nil
local start_pos = nil
local end_pos = nil

local function trim_table(tbl)
    local function is_whitespace(str)
        return str:match("^%s*$") ~= nil
    end

    while #tbl > 0 and (tbl[1] == "" or is_whitespace(tbl[1])) do
        table.remove(tbl, 1)
    end

    while #tbl > 0 and (tbl[#tbl] == "" or is_whitespace(tbl[#tbl])) do
        table.remove(tbl, #tbl)
    end

    return tbl
end

M.model = "mistral:instruct"
M.debugCommand = false
M.show_prompt = false
M.show_model = false
M.auto_close_after_replace = true
M.display_mode = "float"
M.ollama_url = "http://localhost:11434"

M.setup = function(opts)
    M.model = opts.model or M.model
    M.debugCommand = opts.debugCommand or M.debugCommand
    M.win_config = opts.win_config or M.win_config
    M.show_prompt = opts.show_prompt == nil and M.show_prompt or opts.show_prompt
    M.show_model = opts.show_model == nil and M.show_model or opts.show_model
    M.auto_close_after_replace = opts.auto_close_after_replace == nil and M.auto_close_after_replace
        or opts.auto_close_after_replace
    M.ollama_url = opts.ollama_url or M.ollama_url

    if opts.display_mode == "float" or opts.display_mode == "split" then
        M.display_mode = opts.display_mode
    else
        M.display_mode = "float"
    end
end

local function get_window_options()
    local width = math.floor(vim.o.columns * 0.9) -- 90% of the current editor's width
    local height = math.floor(vim.o.lines * 0.9)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local cursor = vim.api.nvim_win_get_cursor(0)
    local new_win_width = vim.api.nvim_win_get_width(0)
    local win_height = vim.api.nvim_win_get_height(0)

    local middle_row = win_height / 2

    local new_win_height = math.floor(win_height / 2)
    local new_win_row
    if cursor[1] <= middle_row then
        new_win_row = 5
    else
        new_win_row = -5 - new_win_height
    end

    return {
        relative = "cursor",
        width = new_win_width,
        height = new_win_height,
        row = new_win_row,
        col = 0,
        style = "minimal",
        border = "single",
    }
end

function write_to_buffer(lines)
    if M.result_buffer ~= nil and not vim.api.nvim_buf_is_valid(M.result_buffer) then
        return
    end

    local all_lines = vim.api.nvim_buf_get_lines(M.result_buffer, 0, -1, false)

    local last_row = #all_lines
    local last_row_content = all_lines[last_row]
    local last_col = string.len(last_row_content)

    local text = table.concat(lines or {}, "\n")

    vim.api.nvim_buf_set_option(M.result_buffer, "modifiable", true)
    vim.api.nvim_buf_set_text(M.result_buffer, last_row - 1, last_col, last_row - 1, last_col, vim.split(text, "\n"))
    vim.api.nvim_buf_set_option(M.result_buffer, "modifiable", false)
end

function create_window(opts, job_id)
    if M.display_mode == "float" then
        if M.result_buffer then
            vim.api.nvim_buf_delete(M.result_buffer, { force = true })
        end
        local win_opts = vim.tbl_deep_extend("force", get_window_options(), opts.win_config)
        M.result_buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_option(M.result_buffer, "filetype", "markdown")

        M.float_win = vim.api.nvim_open_win(M.result_buffer, true, win_opts)
    else
        vim.cmd("vnew")
        M.result_buffer = vim.fn.bufnr("%")
        M.float_win = vim.fn.win_getid()
        vim.api.nvim_buf_set_option(M.result_buffer, "filetype", "markdown")
        vim.api.nvim_win_set_option(M.float_win, "wrap", true)
    end

    local group = vim.api.nvim_create_augroup("gen", { clear = true })
    vim.api.nvim_create_autocmd("BufDelete", {
        buffer = M.result_buffer,
        group = group,
        callback = function()
            vim.fn.jobstop(job_id)
            if M.float_win ~= nil and vim.api.nvim_win_is_valid(M.float_win) then
                vim.api.nvim_win_close(M.float_win, true)
            end
            reset()
        end,
    })
end

function reset()
    M.result_buffer = nil
    M.float_win = nil
    M.result_string = ""
    M.context = nil
end

M.exec = function(options)
    local opts = vim.tbl_deep_extend("force", {
        model = M.model,
        debugCommand = M.debugCommand,
        win_config = M.win_config,
        show_prompt = M.show_prompt,
        show_model = M.show_model,
        auto_close_after_replace = M.auto_close_after_replace,
        ollama_url = M.ollama_url,
    }, options)

    -- TODO: Should there be an option that specifies whether this is local ollama, a docker container, or external url?
    -- This line could be called only if the option is for local ollama
    -- There could be `docker run ...` command to create a container and run ollama in it
    -- or we do neither if it's an external url.
    pcall(io.popen, "ollama serve > /dev/null 2>&1 &")

    curr_buffer = vim.fn.bufnr("%")
    local mode = opts.mode or vim.fn.mode()
    if mode == "v" or mode == "V" then
        start_pos = vim.fn.getpos("'<")
        end_pos = vim.fn.getpos("'>")
        end_pos[3] = vim.fn.col("'>") -- in case of `V`, it would be maxcol instead
    else
        local cursor = vim.fn.getpos(".")
        start_pos = cursor
        end_pos = start_pos
    end

    local content = table.concat(
        vim.api.nvim_buf_get_text(curr_buffer, start_pos[2] - 1, start_pos[3] - 1, end_pos[2] - 1, end_pos[3] - 1, {}),
        "\n"
    )

    local function substitute_placeholders(input)
        if not input then
            return
        end
        local text = input
        if string.find(text, "%$input") then
            local answer = vim.fn.input("Prompt: ")
            text = string.gsub(text, "%$input", answer)
        end

        if string.find(text, "%$register") then
            local register = vim.fn.getreg('"')
            if not register or register:match("^%s*$") then
                error("Prompt uses $register but yank register is empty")
            end

            text = string.gsub(text, "%$register", register)
        end

        content = string.gsub(content, "%%", "%%%%")
        text = string.gsub(text, "%$text", content)
        text = string.gsub(text, "%$filetype", vim.bo.filetype)
        return text
    end

    local prompt = opts.prompt

    if type(prompt) == "function" then
        prompt = prompt({ content = content, filetype = vim.bo.filetype })
    end

    prompt = substitute_placeholders(prompt)
    local extractor = substitute_placeholders(opts.extract)

    prompt = string.gsub(prompt, "%%", "%%%%")

    M.result_string = ""
    local bodyData = {
        model = opts.model,
        prompt = prompt,
        stream = true,
    }

    if M.context then
        bodyData.context = M.context
    end

    local json = vim.fn.json_encode(bodyData)
    local cmd = "curl --silent --no-buffer -X POST "
        .. opts.ollama_url
        .. "/api/generate -d "
        .. vim.fn.shellescape(json)

    if M.context ~= nil then
        write_to_buffer({ "", "", "---", "" })
    end

    if opts.show_prompt then
        local lines = vim.split(prompt, "\n")
        local short_prompt = {}
        for i = 1, #lines do
            lines[i] = "> " .. lines[i]
            table.insert(short_prompt, lines[i])
            if i >= 3 then
                if #lines > i then
                    table.insert(short_prompt, "...")
                end
                break
            end
        end
        local heading = "#"
        if M.show_model then
            heading = "##"
        end
        write_to_buffer({ heading .. " Prompt:", "", table.concat(short_prompt, "\n"), "", "---", "" })
    end

    local partial_data = ""
    local job_id = vim.fn.jobstart(cmd, {
        -- stderr_buffered = opts.debugCommand,
        on_stdout = function(_, data, _)
            -- window was closed, so cancel the job
            if M.float_win == nil or not vim.api.nvim_win_is_valid(M.float_win) then
                vim.fn.jobstop(job_id)
                vim.api.nvim_buf_delete(M.result_buffer, { force = true })
                reset()
                return
            end

            for _, line in ipairs(data) do
                partial_data = partial_data .. line
                if line:sub(-1) == "}" then
                    partial_data = partial_data .. "\n"
                end
            end

            local lines = vim.split(partial_data, "\n", { trimempty = true })

            partial_data = table.remove(lines) or ""

            for _, line in ipairs(lines) do
                process_response(line, job_id)
            end

            if partial_data:sub(-1) == "}" then
                process_response(partial_data, job_id)
                partial_data = ""
            end
        end,
        on_stderr = function(_, data, _)
            if opts.debugCommand then
                -- window was closed, so cancel the job
                if not vim.api.nvim_win_is_valid(M.float_win) then
                    vim.fn.jobstop(job_id)
                    return
                end

                if data == nil or string.len(data) == 0 then
                    return
                end

                M.result_string = M.result_string .. table.concat(data, "\n")
                local lines = vim.split(M.result_string, "\n")
                write_to_buffer(lines)
            end
        end,
        on_exit = function(a, b)
            if b == 0 and opts.replace then
                local lines = {}
                if extractor then
                    local extracted = M.result_string:match(extractor)
                    if not extracted then
                        if opts.auto_close_after_replace then
                            vim.api.nvim_win_hide(M.float_win)
                            vim.api.nvim_buf_delete(M.result_buffer, { force = true })
                            reset()
                        end
                        return
                    end
                    lines = vim.split(extracted, "\n", true)
                else
                    lines = vim.split(M.result_string, "\n", true)
                end
                lines = trim_table(lines)
                vim.api.nvim_buf_set_text(
                    curr_buffer,
                    start_pos[2] - 1,
                    start_pos[3] - 1,
                    end_pos[2] - 1,
                    end_pos[3] - 1,
                    lines
                )
                if opts.auto_close_after_replace then
                    vim.api.nvim_win_hide(M.float_win)
                    vim.api.nvim_buf_delete(M.result_buffer, { force = true })
                    reset()
                end
            end
            M.result_string = ""
        end,
    })

    if M.result_buffer == nil or M.float_win == nil or not vim.api.nvim_win_is_valid(M.float_win) then
        create_window(opts, job_id)
        if M.show_model then
            write_to_buffer({ "# Chat with " .. opts.model, "" })
        end
    end

    vim.keymap.set("n", "<esc>", function()
        vim.fn.jobstop(job_id)
    end, { buffer = M.result_buffer })

    vim.api.nvim_buf_attach(M.result_buffer, false, {
        on_detach = function()
            M.result_buffer = nil
        end,
    })
end

M.win_config = {}

M.prompts = prompts
function select_prompt(cb)
    local promptKeys = {}
    for key, _ in pairs(M.prompts) do
        table.insert(promptKeys, key)
    end
    table.sort(promptKeys)
    vim.ui.select(promptKeys, {
        prompt = "Prompt:",
        format_item = function(item)
            return table.concat(vim.split(item, "_"), " ")
        end,
    }, function(item, idx)
        cb(item)
    end)
end

vim.api.nvim_create_user_command("Gen", function(arg)
    local mode
    if arg.range == 0 then
        mode = "n"
    else
        mode = "v"
    end
    if arg.args ~= "" then
        local prompt = M.prompts[arg.args]
        if not prompt then
            print("Invalid prompt '" .. arg.args .. "'")
            return
        end
        p = vim.tbl_deep_extend("force", { mode = mode }, prompt)
        return M.exec(p)
    end
    select_prompt(function(item)
        if not item then
            return
        end
        p = vim.tbl_deep_extend("force", { mode = mode }, M.prompts[item])
        M.exec(p)
    end)
end, {
    range = true,
    nargs = "?",
    complete = function(ArgLead, CmdLine, CursorPos)
        local promptKeys = {}
        for key, _ in pairs(M.prompts) do
            if key:lower():match("^" .. ArgLead:lower()) then
                table.insert(promptKeys, key)
            end
        end
        table.sort(promptKeys)
        return promptKeys
    end,
})

function process_response(str, job_id)
    if string.len(str) == 0 then
        return
    end

    local success, result = pcall(function()
        return vim.fn.json_decode(str)
    end)

    local body = {}
    if success then
        body = result
    else
        write_to_buffer({ "", "====== ERROR ====", str, "-------------", "" })
        vim.fn.jobstop(job_id)
    end

    if body == nil then
        return
    end

    M.result_string = M.result_string .. body.response
    local lines = vim.split(body.response, "\n")
    write_to_buffer(lines)

    if body.context ~= nil then
        M.context = body.context
    end
end

return M
