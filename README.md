# AIMentor_Asynchronous
这是一个为《魔兽世界》3.3.5客户端设计的插件，通过输入 @mentor 命令，利用本地OLLAMA大模型进行异步、多轮对话。
标题与简介：这是在服务端的luajit的文件，两大核心特点（异步调用、多轮对话）及其价值。
功能演示：
安装与配置：

安装：说明将 AIMentor_Asynchronous 文件夹复制到 Azerothcore的bin/luajit/Interface/AddOns/ 目录下。
配置：指导用户如何修改 Config.lua 以指向其本地OLLAMA服务端点。
前置依赖：明确告知用户需要提前安装并运行OLLAMA，并可能需要LuaJIT或特定的LuaSocket库（如果你的实现涉及网络通信）。

使用方法：详细说明游戏内命令（如 @mentor 或你设定的命令）以及如何开始和进行多轮对话。
技术架构：简要说明插件如何通过Lua与本地服务进行异步通信，以及如何管理对话状态以实现多轮对话。
贡献指南：欢迎他人提交问题（Issues）和拉取请求（Pull Requests）。
