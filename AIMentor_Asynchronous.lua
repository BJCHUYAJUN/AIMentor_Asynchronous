-- 配置Lua模块搜索路径
package.path = package.path .. 
    ';/usr/local/share/lua/5.1/?.lua' ..
    ';/usr/share/lua/5.1/?.lua' ..
    ';/usr/local/lib/lua/5.1/?.lua' ..
    ';/usr/local/lib/luarocks/rocks-5.1/dkjson/2.5-3/lua/?.lua'

local OllamaNPC = {}
local dkjson = require("dkjson")

-- 核心配置（优化性能参数）
-- 配置IP地址和端口号
OllamaNPC.OLLAMA_BASE_URL = "http://IP地址:端口号"
OllamaNPC.COMMAND_PREFIX = "@mentor"
OllamaNPC.MAX_HISTORY = 10
--配置模型
OllamaNPC.DEFAULT_MODEL = "deepseek-r1:14b"
OllamaNPC.ConversationHistory = {}
OllamaNPC.RECV_TIMEOUT = 120  -- 适当缩短超时（避免不必要等待）
OllamaNPC.GLOBAL_TIMEOUT = 150
OllamaNPC.MAX_MSG_LENGTH = 255
OllamaNPC.RECV_BUFFER_SIZE = 8192  -- 增大接收缓冲区（原4096）
OllamaNPC.POLL_INTERVAL = 50  -- 减小轮询间隔（原100ms，提升响应速度）

-- 系统常量
local SOL_SOCKET = 65535
local SO_ERROR = 4
local EAGAIN = 11
local F_GETFL = 1
local F_SETFL = 2
local O_NONBLOCK = 4
local AF_INET = 2
local SOCK_STREAM = 1
local MSG_DONTWAIT = 0x40
local AI_PASSIVE = 1
local AI_CANONNAME = 2

-- 异步任务管理器
local AsyncTasks = {}
local TaskId = 0

-- FFI定义
local ffi = require("ffi")
ffi.cdef[[
    typedef unsigned short sa_family_t;
    typedef uint32_t in_addr_t;
    typedef uint16_t in_port_t;
    typedef int socklen_t;
    
    struct in_addr { in_addr_t s_addr; };
    struct sockaddr_in { sa_family_t sin_family; in_port_t sin_port; struct in_addr sin_addr; char sin_zero[8]; };
    struct sockaddr { sa_family_t sa_family; char sa_data[14]; };
    struct addrinfo {
        int ai_flags;
        int ai_family;
        int ai_socktype;
        int ai_protocol;
        socklen_t ai_addrlen;
        struct sockaddr *ai_addr;
        char *ai_canonname;
        struct addrinfo *ai_next;
    };
    
    int socket(int domain, int type, int protocol);
    int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
    ssize_t send(int sockfd, const void *buf, size_t len, int flags);
    ssize_t recv(int sockfd, void *buf, size_t len, int flags);
    int close(int fd);
    int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res);
    void freeaddrinfo(struct addrinfo *res);
    uint16_t htons(uint16_t hostshort);
    int fcntl(int fd, int cmd, int arg);
    int getsockopt(int sockfd, int level, int optname, void *optval, socklen_t *optlen);
    int errno;
    const char *strerror(int errnum);
]]

-- 错误描述
local function get_errno_desc(errno)
    local c_str = ffi.C.strerror(errno)
    return c_str and ffi.string(c_str) or "未知错误"
end

-- 设置非阻塞Socket
local function set_nonblocking(sockfd)
    local flags = ffi.C.fcntl(sockfd, F_GETFL, 0)
    if flags == -1 then return false end
    local result = ffi.C.fcntl(sockfd, F_SETFL, flags + O_NONBLOCK)
    return result ~= -1
end

-- 清理响应体（提取完整JSON）
local function clean_json_response(raw_body)
    local json_str = raw_body:match("{.*}")  -- 提取完整JSON
    return json_str and json_str:gsub("\\\\", "\\") or nil
end

-- 清理回答内容（核心：过滤###和多余格式）
local function clean_answer_content(content)
    -- 1. 移除###及后面的标题（如### 标题 → 空）
    content = content:gsub("###+%s*[%w%p%s]*\n?", "")
    -- 2. 移除其他可能的格式符号（如**、__等）
    content = content:gsub("%*%*+", ""):gsub("__+", "")
    -- 3. 统一换行，去除首尾空格
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    return content:gsub("^%s+", ""):gsub("%s+$", "")
end

-- 异步HTTP请求（优化速度和完整性）
local function async_http_request(base_url, api_path, data, callback)
    TaskId = TaskId + 1
    local task = {
        id = TaskId,
        state = "init",
        sockfd = -1,
        response = "",  -- 完整接收响应体
        sent_bytes = 0,
        request_data = data,
        callback = callback,
        global_timeout = os.time() + OllamaNPC.GLOBAL_TIMEOUT,
        last_recv_time = 0,
        addrinfo = nil
    }
    AsyncTasks[task.id] = task

    -- 解析URL
    local host, port = base_url:match("^http://([^:]+):?(%d*)$")
    if not host then
        callback(nil, "无效的服务地址（正确：http://IP:端口）")
        AsyncTasks[task.id] = nil
        return
    end
    port = port == "" and "11434" or tostring(port)
    task.host = host
    task.port = port
    task.path = api_path or "/api/chat"

    -- 创建Socket
    local sockfd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    if sockfd == -1 then
        callback(nil, "创建连接失败：" .. get_errno_desc(ffi.C.errno))
        AsyncTasks[task.id] = nil
        return
    end
    task.sockfd = sockfd

    -- 设置非阻塞
    if not set_nonblocking(sockfd) then
        ffi.C.close(sockfd)
        callback(nil, "连接初始化失败")
        AsyncTasks[task.id] = nil
        return
    end

    -- DNS解析
    local hints = ffi.new("struct addrinfo")
    ffi.fill(hints, ffi.sizeof(hints))
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    local res = ffi.new("struct addrinfo*[1]")

    local gai_err = ffi.C.getaddrinfo(host, port, hints, res)
    if gai_err ~= 0 then
        ffi.C.close(sockfd)
        callback(nil, "无法解析服务地址")
        AsyncTasks[task.id] = nil
        return
    end
    task.addrinfo = res[0]

    -- 发起连接
    local connect_result = ffi.C.connect(sockfd, task.addrinfo.ai_addr, task.addrinfo.ai_addrlen)
    if connect_result == 0 then
        task.state = "sending"
        task.http_request = string.format(
            "POST %s HTTP/1.1\r\n" ..
            "Host: %s:%s\r\n" ..
            "Content-Type: application/json\r\n" ..
            "Content-Length: %d\r\n" ..
            "Connection: close\r\n" ..
            "\r\n%s",
            task.path, task.host, task.port, #task.request_data, task.request_data
        )
    else
        if ffi.C.errno ~= 105 then  -- 105=EINPROGRESS（连接中）
            ffi.C.freeaddrinfo(task.addrinfo)
            ffi.C.close(sockfd)
            callback(nil, "连接服务失败：" .. get_errno_desc(ffi.C.errno))
            AsyncTasks[task.id] = nil
            return
        end
        task.state = "connecting"
    end

    -- 轮询任务（优化速度：缩短间隔）
    local function poll_task()
        local task = AsyncTasks[task.id]
        if not task then return end

        -- 全局超时
        if os.time() > task.global_timeout then
            ffi.C.close(task.sockfd)
            if task.addrinfo then ffi.C.freeaddrinfo(task.addrinfo) end
            task.callback(nil, "请求超时（超过" .. OllamaNPC.GLOBAL_TIMEOUT .. "秒）")
            AsyncTasks[task.id] = nil
            return
        end

        if task.sockfd == -1 then
            task.callback(nil, "连接已关闭")
            AsyncTasks[task.id] = nil
            return
        end

        -- 处理连接中
        if task.state == "connecting" then
            local error = ffi.new("int[1]")
            local optlen = ffi.new("socklen_t[1]")
            optlen[0] = ffi.sizeof("int")
            
            local opt_result = ffi.C.getsockopt(task.sockfd, SOL_SOCKET, SO_ERROR, error, optlen)
            if opt_result == -1 then
                local err_no = ffi.C.errno
                if err_no == 95 then  -- 协议不支持选项，忽略
                    task.state = "sending"
                    task.http_request = string.format(
                        "POST %s HTTP/1.1\r\n" ..
                        "Host: %s:%s\r\n" ..
                        "Content-Type: application/json\r\n" ..
                        "Content-Length: %d\r\n" ..
                        "Connection: close\r\n" ..
                        "\r\n%s",
                        task.path, task.host, task.port, #task.request_data, task.request_data
                    )
                elseif err_no ~= 105 then  -- 非连接中状态
                    ffi.C.close(task.sockfd)
                    task.sockfd = -1
                    if task.addrinfo then ffi.C.freeaddrinfo(task.addrinfo) end
                    task.callback(nil, "连接异常：" .. get_errno_desc(err_no))
                    AsyncTasks[task.id] = nil
                    return
                end
            else
                if error[0] == 0 then  -- 连接成功
                    task.state = "sending"
                    task.http_request = string.format(
                        "POST %s HTTP/1.1\r\n" ..
                        "Host: %s:%s\r\n" ..
                        "Content-Type: application/json\r\n" ..
                        "Content-Length: %d\r\n" ..
                        "Connection: close\r\n" ..
                        "\r\n%s",
                        task.path, task.host, task.port, #task.request_data, task.request_data
                    )
                else  -- 连接失败
                    ffi.C.close(task.sockfd)
                    task.sockfd = -1
                    if task.addrinfo then ffi.C.freeaddrinfo(task.addrinfo) end
                    task.callback(nil, "连接失败：" .. get_errno_desc(error[0]))
                    AsyncTasks[task.id] = nil
                    return
                end
            end

        -- 处理发送
        elseif task.state == "sending" then
            local total_len = #task.http_request
            local remaining = total_len - task.sent_bytes
            if remaining > 0 then
                local send_str = task.http_request:sub(task.sent_bytes + 1, task.sent_bytes + remaining)
                local buf = ffi.new("char[?]", remaining, send_str)
                local sent = ffi.C.send(task.sockfd, buf, remaining, MSG_DONTWAIT)
                if sent > 0 then
                    task.sent_bytes = task.sent_bytes + sent
                    if task.sent_bytes == total_len then
                        task.state = "receiving"
                        task.last_recv_time = os.time()
                    end
                elseif sent == -1 and ffi.C.errno ~= EAGAIN then  -- 发送错误
                    ffi.C.close(task.sockfd)
                    task.sockfd = -1
                    if task.addrinfo then ffi.C.freeaddrinfo(task.addrinfo) end
                    task.callback(nil, "发送失败：" .. get_errno_desc(ffi.C.errno))
                    AsyncTasks[task.id] = nil
                    return
                end
            end

        -- 处理接收（优化：增大缓冲区，提升效率）
        elseif task.state == "receiving" then
            -- 接收超时（最后一次接收后超过设定时间）
            if os.time() > task.last_recv_time + OllamaNPC.RECV_TIMEOUT then
                ffi.C.close(task.sockfd)
                task.sockfd = -1
                if task.addrinfo then ffi.C.freeaddrinfo(task.addrinfo) end
                task.callback(nil, "接收超时（超过" .. OllamaNPC.RECV_TIMEOUT .. "秒）")
                AsyncTasks[task.id] = nil
                return
            end

            -- 增大接收缓冲区（8192字节），减少接收次数
            local buffer = ffi.new("char[?]", OllamaNPC.RECV_BUFFER_SIZE)
            local received = ffi.C.recv(task.sockfd, buffer, OllamaNPC.RECV_BUFFER_SIZE, MSG_DONTWAIT)
            if received > 0 then
                task.response = task.response .. ffi.string(buffer, received)
                task.last_recv_time = os.time()  -- 刷新超时
            elseif received == 0 then  -- 接收完成（连接正常关闭）
                ffi.C.close(task.sockfd)
                task.sockfd = -1
                if task.addrinfo then ffi.C.freeaddrinfo(task.addrinfo) end
                -- 提取完整响应体
                local status_line, header_rest = task.response:match("^([^\r\n]+)\r\n(.*)")
                local status_code = status_line and status_line:match("HTTP/%d+%.%d+ (%d+)") or 0
                local header_end = header_rest and header_rest:find("\r\n\r\n")
                local body = header_end and header_rest:sub(header_end + 4) or ""
                task.callback({
                    status_code = tonumber(status_code),
                    body = body
                }, nil)
                AsyncTasks[task.id] = nil
                return
            elseif received == -1 and ffi.C.errno ~= EAGAIN then  -- 接收错误
                ffi.C.close(task.sockfd)
                task.sockfd = -1
                if task.addrinfo then ffi.C.freeaddrinfo(task.addrinfo) end
                task.callback(nil, "接收失败：" .. get_errno_desc(ffi.C.errno))
                AsyncTasks[task.id] = nil
                return
            end
        end

        -- 缩短轮询间隔（50ms），提升响应速度
        CreateLuaEvent(poll_task, OllamaNPC.POLL_INTERVAL, 1)
    end

    CreateLuaEvent(poll_task, OllamaNPC.POLL_INTERVAL, 1)
end

-- 异步查询Ollama（优化生成完整性）
function OllamaNPC.asyncQueryOllama(playerLowGUID, userMessage, callback)
    if not OllamaNPC.OLLAMA_BASE_URL:match("^http://[^:]+:%d+$") then
        callback("服务地址格式错误", true)
        return
    end

    local history = OllamaNPC.ConversationHistory[playerLowGUID] or {}
    local requestData = {
        model = OllamaNPC.DEFAULT_MODEL,
        messages = {},
        stream = false,
        -- 关键：控制模型生成完整内容
        options = {
            max_tokens = 2048,  -- 增大生成长度上限（根据模型调整）
            temperature = 0.7,
            stop = {}  -- 正确：Lua 用 {} 定义空表
        }
    }

    -- 构建对话历史
    local start_index = math.max(1, #history - (OllamaNPC.MAX_HISTORY - 1))
    for i = start_index, #history do
        table.insert(requestData.messages, history[i])
    end
    table.insert(requestData.messages, {role = "user", content = userMessage})
 
    -- 序列化请求
    local jsonRequest, jsonErr = dkjson.encode(requestData)
    if not jsonRequest then
        callback("请求格式错误：" .. tostring(jsonErr), true)
        return
    end

    -- 发送请求
    async_http_request(OllamaNPC.OLLAMA_BASE_URL, "/api/chat", jsonRequest, function(response, err)
        if err then
            callback(err, true)
            return
        end

        -- 处理HTTP状态码
        if response.status_code == 404 then
            callback("未找到服务接口（请确认版本≥0.1.30）", true)
            return
        elseif response.status_code >= 500 then
            local err_data = dkjson.decode(response.body)
            local err_msg = err_data and err_data.error or "服务错误"
            callback("服务错误：" .. err_msg, true)
            return
        elseif response.status_code ~= 200 then
            callback("请求异常（状态码：" .. response.status_code .. "）", true)
            return
        end

        -- 清理并解析响应
        local clean_body = clean_json_response(response.body)
        if not clean_body then
            callback("响应格式错误", true)
            return
        end

        local parsedData, parseErr = dkjson.decode(clean_body)
        if type(parsedData) ~= "table" or not parsedData.message or not parsedData.message.content then
            callback("解析失败：" .. tostring(parseErr), true)
            return
        end

        -- 清理回答内容（过滤###等格式）
        local content = clean_answer_content(parsedData.message.content)
        if #content == 0 then
            callback("未获取到有效回答", true)
            return
        end

        -- 更新对话历史
        table.insert(history, {role = "user", content = userMessage})
        table.insert(history, {role = "assistant", content = content})
        while #history > OllamaNPC.MAX_HISTORY do
            table.remove(history, 1)
        end
        OllamaNPC.ConversationHistory[playerLowGUID] = history

        callback(content, false)
    end)
end

-- 聊天事件处理
local function OnChatEvent(event, player, msg, lang, receiver)
    local is_player_valid, guid = pcall(function() return player:GetGUID() end)
    if not is_player_valid or not guid then return true end
    local playerGUID = tostring(guid)
    local playerLowGUID = tostring(player:GetGUIDLow())

    local clean_msg = msg:gsub("^%s+", ""):gsub("%s+$", "")
    local prefix = OllamaNPC.COMMAND_PREFIX
    local prefix_len = #prefix
    if clean_msg:sub(1, prefix_len) ~= prefix then return true end

    local question = clean_msg:sub(prefix_len + 1):gsub("^%s+", "")
    if question == "" then
        player:SendBroadcastMessage("智慧导师：请输入问题（例如：@mentor 你好）")
        return false
    end

    player:SendBroadcastMessage("【智慧导师】正在思考，请稍候...")

    -- 调用Ollama查询
    OllamaNPC.asyncQueryOllama(playerLowGUID, question, function(npcReply, isError)
        local targetPlayer = GetPlayerByGUID(playerGUID)
        if not targetPlayer then return end
        local is_valid, in_world = pcall(function() return targetPlayer:IsInWorld() end)
        if not is_valid or not in_world then return end

        if isError then
            targetPlayer:SendBroadcastMessage("【系统提示】" .. npcReply)
        else
            -- 分块发送完整内容
            local max_len = OllamaNPC.MAX_MSG_LENGTH
            for i = 1, #npcReply, max_len do
                local chunk = npcReply:sub(i, i + max_len - 1)
                targetPlayer:SendBroadcastMessage("【智慧导师】" .. chunk)
            end
        end
    end)

    return false
end

-- 启动检查
local function check_ollama_connection()
    local test_data = dkjson.encode({
        model = OllamaNPC.DEFAULT_MODEL,
        messages = {{role = "user", content = "test"}},
        stream = false,
        options = {max_tokens = 100}
    })
    async_http_request(OllamaNPC.OLLAMA_BASE_URL, "/api/chat", test_data, function(response, err)
        if err then
            print("【Ollama检查】连接失败：" .. err)
        else
            if response.status_code == 200 and clean_json_response(response.body) then
                print("【Ollama检查】服务正常")
            else
                print("【Ollama检查】响应异常")
            end
        end
    end)
end

-- 注册事件
local eventId = 18
RegisterPlayerEvent(eventId, OnChatEvent)
check_ollama_connection()
print("Ollama NPC模块加载成功（指令：" .. OllamaNPC.COMMAND_PREFIX .. "）")

return OllamaNPC
