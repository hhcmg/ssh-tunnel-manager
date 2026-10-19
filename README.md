# SSH Tunnel Manager

在 Windows 上选择需要连接的 Linux 服务器，将本机 HTTP 代理通过反向 SSH 隧道提供给远端应用。每台服务器由独立的后台 worker 维护，支持重复启动检查、断线重连和安全停止。

你可以使用现有 SSH 配置中的普通主机别名，也可以指定独立的 SSH 配置文件。无需修改脚本中的服务器列表，也无需为普通别名添加 `RemoteForward`。

## 运行条件

- 本机：Windows、Windows PowerShell 5.1 和 Windows OpenSSH 客户端。
- 本机有支持 HTTP CONNECT 的代理，例如监听 `127.0.0.1:7897` 的 HTTP 或混合代理端口；仅 SOCKS 端口不适用当前健康检查。
- 远端：Linux、可读的 `/proc`、Python 3.7 或更新版本、非 root SSH 用户，允许执行远端命令和远端 TCP 转发。
- SSH 可以通过密钥或 `ssh-agent` 完成非交互登录。后台 worker 不提示输入登录密码、私钥口令或主机密钥确认。
- 项目目录可供当前 Windows 用户写入，用于保存本地配置与运行状态。

Python 只在远端运行 guard；本机日常启动不需要 Python。本机运行 guard 离线测试时需要 Python。

## 快速开始

1. 准备 SSH 配置。默认位置是 `%USERPROFILE%\.ssh\config`，也可使用任意自选文件。参考 [ssh-config.example](ssh-config.example)，填入自己的主机地址、用户名和密钥路径。
2. 在普通 PowerShell 中先登录各目标一次，核实服务器主机密钥并完成认证准备。以下命令会关闭配置中已有的端口转发，避免首次登录占用隧道端口：

   ```powershell
   ssh -F "$env:USERPROFILE\.ssh\config" -o ClearAllForwardings=yes server-a
   ```

   自定义 SSH 配置时替换 `-F` 后的路径；连接跳板机的场景也应先验证完整登录链路。
3. 开启本机代理，双击 `Start-Tunnels.cmd`。
4. 首次启动时选择 SSH 配置文件，再按编号选择一台或多台服务器。支持选择全部列出的别名，也可手动输入未列出的具体别名。选择保存到 `tunnels.local.json`。
5. 检查完成后可关闭窗口。后台 worker 会继续维护隧道；以后双击会按保存的选择运行。

日常使用的三个双击入口：`Configure-Tunnels.cmd` 重新选择 SSH 来源和服务器并保存，`Start-Tunnels.cmd` 启动或检查，`Stop-Tunnels.cmd` 停止当前选择的隧道。配置入口只保存选择，不建立隧道；完成后再双击启动入口。

默认情况下，远端应用使用 `http://127.0.0.1:7897`。例如在远端 shell 中：

```sh
export http_proxy=http://127.0.0.1:7897
export https_proxy=http://127.0.0.1:7897
```

代理环境变量是否生效取决于应用；有些应用使用大写变量或自己的设置。HTTPS 通过 HTTP 代理的 CONNECT 方式转发，因此这里的代理 URL 仍使用 `http://`。工具不会自动修改远端应用或 shell 配置。

## 选择服务器和 SSH 来源

双击 `Configure-Tunnels.cmd` 即可重新打开选择向导，无需打开命令行。它等同于下面的 `-Configure` 命令。

以下命令在项目目录内的 PowerShell 中运行。若执行策略阻止脚本，可使用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Tunnels.ps1` 加上相同参数。

```powershell
# 重新选择来源文件和目标，只保存配置；随后另行启动
.\Start-Tunnels.ps1 -Configure

# 查看来源文件中发现的具体 Host 别名，不建立隧道
.\Start-Tunnels.ps1 -SshConfig 'C:\ssh\config' -ListHosts

# 本次只为指定目标建立隧道
.\Start-Tunnels.ps1 -Targets server-a,server-b

# 本次使用另一个 SSH 来源和目标
.\Start-Tunnels.ps1 -SshConfig 'C:\ssh\config' -Targets server-a

# 从另一份管理器配置读取端口和目标；不允许交互提示
.\Start-Tunnels.ps1 -ConfigPath .\lab.local.json -NonInteractive

# 只检查现有隧道，不创建 worker 或请求重连
.\Start-Tunnels.ps1 -CheckOnly -NonInteractive

# 严格检查：CONNECT 未返回 200 时也使用非零退出码
.\Start-Tunnels.ps1 -CheckOnly -RequireProxySuccess -NonInteractive
```

`.cmd` 入口也传递参数。通过 `.cmd` 或 `powershell.exe -File` 调用多个目标时，将别名写成一个逗号分隔的参数，例如：

```bat
Start-Tunnels.cmd -Targets server-a,server-b -NonInteractive
Start-Tunnels.cmd -CheckOnly -NonInteractive
```

无参数双击时窗口会保留足够时间查看结果；传入参数时入口直接返回退出码，适合脚本调用。

`-Targets` 和 `-SshConfig` 覆盖本次运行的选择；要更新默认选择，使用 `-Configure` 或编辑个人 JSON 配置。`-NonInteractive` 遇到缺少必要配置时返回错误，不替你选择所有服务器。

`-Configure` 仅配置，不启动隧道。首次无配置的正常启动会在向导保存后继续启动。`-ListHosts` 和 `-CheckOnly` 不写配置。

选择列表决定本次启动或检查的范围，不会自动停止已经运行但本次未选中的服务器。取消选择后仍需关闭某台隧道时，使用 `Stop-Tunnels.ps1 -Targets 原别名`；默认停止命令只处理当前配置选中的目标。

主机列表由 `Host` 声明发现，尽力展开 `Include` 文件；`Host *`、通配模式和否定模式不作为可选服务器。列表发现并非完整的 OpenSSH 配置解析器：复杂条件或动态生成的别名可以手动输入，最终有效参数以所选 SSH 客户端的 `ssh -G` 结果为准。`Include` 路径本身遵循 OpenSSH 的规则，详见 [官方配置说明](https://man.openbsd.org/ssh_config#Include)。

工具通过 `ssh -F` 使用选定配置，保留该文件中认证、连接端口和跳板机等设置。只读取可信的本地 SSH 配置；其中的 `ProxyCommand`、`Match exec` 等设置可能执行本地命令。此工具不导入密码，也不复制私钥。

## 配置文件

将 [tunnels.example.json](tunnels.example.json) 复制为 `tunnels.local.json` 后按需修改，或由首次运行向导生成。JSON 不支持注释，Windows 路径可以使用 `/`，或将反斜杠写为 `\\`。

| 字段 | 默认值 | 用途 |
| --- | --- | --- |
| `Version` | `1` | 配置格式版本 |
| `SshConfigPath` | `~/.ssh/config` | 要读取的 SSH 配置文件 |
| `SshExecutable` | `""` | 留空自动查找 SSH 客户端；也可指定完整 `ssh.exe` 路径 |
| `Targets` | 用户选择 | 要维护的 SSH 主机别名数组 |
| `LocalProxyHost` | `127.0.0.1` | Windows 可访问的 HTTP 代理地址 |
| `LocalProxyPort` | `7897` | 本机代理端口 |
| `RemotePort` | `7897` | 每台远端服务器上的回环监听端口 |
| `ProbeHost` | `www.microsoft.com` | HTTP CONNECT 检查目标；可改成自己的稳定目标 |
| `ProbePort` | `443` | HTTP CONNECT 检查目标端口 |

同一份配置的所有目标使用相同代理和监听端口。需要不同端口时使用不同配置文件。两份配置连接到同一服务器时，不要让它们争用同一个远端监听端口。

`-ConfigPath` 的相对路径以项目目录为基准。`SshConfigPath` 和显式指定的 `SshExecutable` 相对路径以 JSON 配置所在目录为基准；命令行 `-SshConfig` 的相对路径也采用这个基准。支持 `~` 和环境变量展开。别名使用 1–128 个 ASCII 字符，以字母或数字开头，随后可含字母、数字、点、下划线和连字符；Windows 保留设备名不可用。

管理器会为普通 SSH 别名设置所需的反向转发。兼容配置中已有且与本次设置一致的一条 `RemoteForward`；检测到额外的 `RemoteForward`、`LocalForward` 或 `DynamicForward` 时会报错。此时可新建一个仅包含登录设置的专用别名。

## 检查与停止

```powershell
# 检查指定目标
.\Start-Tunnels.ps1 -Targets server-a -CheckOnly -NonInteractive

# 停止默认配置选择的所有隧道
.\Stop-Tunnels.ps1

# 只停止一台
.\Stop-Tunnels.ps1 -Targets server-a

# 停止自定义配置的隧道
.\Stop-Tunnels.ps1 -ConfigPath .\lab.local.json

# 跨配置停止本项目记录的所有 worker；SSH 来源丢失或修改后也可使用
.\Stop-Tunnels.ps1 -All
```

也可双击 `Stop-Tunnels.cmd`。默认停止入口以非交互方式读取配置；停止时必须使用与启动时对应的配置和 SSH 来源。停止请求带有 worker 的本次身份标记，worker 收到后退出并释放其 SSH 会话；不会按端口扫描并杀掉其他 SSH 连接。仅手工结束 SSH 子进程会触发 worker 重连。全部选定目标停止成功时退出码为 0，否则为 1。

`-All` 是独立的恢复入口：直接扫描本项目 `.runtime/` 中的记录，不读取 SSH 配置，也不依赖原 SSH 可执行文件仍然存在；只对身份可以核验的 worker 发出停止请求。它不能与 `-ConfigPath`、`-SshConfig` 或 `-Targets` 同时使用，也不会扫描其他安装目录或旧版项目。对应的命令行入口是 `Stop-Tunnels.cmd -All`。

运行结果需要区分连接和代理：

| 结果 | 含义 |
| --- | --- |
| `OK` / `CONNECT HTTP 200` | 本次检查中，远端代理成功建立到检查目标的 CONNECT 连接 |
| `WARN` / 其他 HTTP 状态 | 代理有响应，但到检查目标的连接未成功；检查代理认证、策略或上游 |
| `WARN` / `not ready yet` | 尚未确认隧道就绪；已启动的 worker 会继续尝试 |
| 配置、认证或端口错误 | 查看屏幕提示和当前上下文日志 |

默认退出码主要表示隧道管理检查是否成功；代理返回非 200 HTTP 响应可能只产生警告。加上 `-RequireProxySuccess` 后，此类结果返回退出码 1，仍不会仅因 HTTP 错误重启 SSH。即使 CONNECT 成功，也只证明本次检查目标可连接。`-CheckOnly` 不暂停正在运行的 worker，它们仍会自行重连。

## 后台行为与边界

- 每台目标有独立 worker，维护专用 SSH 连接。工具禁止连接复用、`ssh-agent` 转发和 X11 转发，避免 guard 回收影响共用会话。
- worker 每 5 秒发送带 token 的心跳。远端 guard 确认会话身份后，若连续 30 秒未收到有效心跳或输入结束，会再次核验并尝试回收本次专用 SSH 会话。
- SSH 退出、心跳失败或 READY 超时后重连，退避间隔最高 10 秒。连接前本机代理不可达时每 5 秒等待一次。
- 完整远端 HTTP CONNECT 检查在调用启动器时进行。常驻 worker 监控 SSH 和心跳，不定时测试代理上游；上游访问失败不一定触发重连。
- 没有安装 Windows 服务、计划任务或远端常驻服务。Windows 重启或 worker 自身退出后，需要再次启动。
- guard 依赖 Linux 的进程结构和 `/proc` 身份信息；不支持 root 用户。优先使用 `pidfd` 固定进程身份，不具备该能力的系统会走重新核验 PID 的回退路径，仍存在很窄的 PID 重用竞争窗口。请在计划支持的远端系统上验证。

## 状态与日志

运行文件位于项目内的 `.runtime/<配置上下文标识>/`，与源码和个人配置分开。不同 SSH 来源或端口配置使用各自的上下文；不要手动搬移活动状态文件来接管 worker。

同一 Windows 用户会话中，相同设置的单例标识不依赖项目目录，所以复制项目不会得到第二组重复 worker；但另一个安装目录不能自动接管已有安装的状态。请从原目录停止后再迁移。

- `*.worker.json`：worker 与 SSH 进程身份、状态、更新时间和最近错误。
- `logs/tunnels.log`：启动、检查的摘要。
- `logs/*.worker.log`：worker 生命周期和重连记录。
- `logs/<别名>.<时间>.log`：对应 SSH 会话的诊断输出。
- `*.reconnect`、`*.stop`：发给当前 worker 的一次性请求。

状态文件采用原子替换；日志轮换和清理失败不会主动断开正常 SSH 连接。日志按大小轮换，并保留当前会话及少量历史会话日志。运行中的状态文件不应删除；停止相关 worker 后可以清理不需要的历史运行目录。

`tunnels.local.json`、`*.local.json`、`.runtime/` 和日志已在 `.gitignore` 中排除。使用其他名称存放个人配置时，也要将其加入忽略规则。日志和状态可能含服务器地址、用户名、本机路径及会话 token，提交 issue 前先脱敏。

## 远端监听范围

工具请求远端仅监听 `127.0.0.1`。服务端 `GatewayPorts yes` 会强制通配监听，客户端请求不能覆盖这一行为；应由管理员核实 `GatewayPorts no` 或合适的 `clientspecified` 设置，并检查实际监听地址。[OpenSSH 官方说明](https://man.openbsd.org/sshd_config#GatewayPorts)

回环监听意味着同一服务器上的其他用户也可能访问该代理，不是按 Linux 用户隔离。请仅在允许共享代理的服务器上使用，并遵守代理和服务器的访问策略。

## 常见问题

**无法发现想连接的服务器**：核实 `-SshConfig` 指向的文件；通配或条件配置可能不会出现在列表中，可以输入具体别名，再让 `ssh -G` 校验。不要将 `HostName`、IP、用户名和密码填入管理器配置来替代 SSH 配置。

**身份认证失败或主机密钥未确认**：用快速开始中的命令在普通终端先完成 SSH 登录。确保运行 worker 的同一 Windows 用户能够使用密钥或 `ssh-agent`。

**`remote port forwarding failed`**：远端端口可能被旧 worker、另一个配置或其他服务占用，也可能是服务器禁止转发。先核实占用者归属；工具不会自动结束未知监听者。

**更换了 SSH 来源、代理地址或端口后旧隧道还在**：修改之前，先用旧配置停止所有受影响的 worker，再切换配置。修改配置不会自动迁移或接管旧上下文。修改同一 SSH 文件中已有别名的 `HostName`、`User` 等连接设置前也应先停止；已经建立的连接不会因文件内容变化而自动重新连接。

**配置已被移动、删除或改坏，默认停止命令失败**：使用 `Stop-Tunnels.ps1 -All`，根据本项目原有运行记录停止可核验的 worker。若状态文件也被删除或身份无法确认，工具不会猜测需要结束的进程。

**从旧版本迁移**：新项目的运行目录与旧脚本独立，不会自动接管旧 worker。首次在同一远端端口运行前，先明确停止旧版本的对应 worker 和其会话；也可以先用未占用的高端口验证新版本。保留旧源码不会影响新项目。

**本机代理关闭**：新连接会等待本机代理恢复；已有 SSH 会话可能仍在线。代理恢复后重新调用启动器检查实际 CONNECT 结果。

## 开发验证

离线测试不连接真实服务器，不结束真实 SSH 进程；文件测试只使用自己创建的临时目录。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Tunnels.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-State-IO.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Tunnel-Logs.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Tunnel-Config.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Tunnel-Options.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Worker-Control.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Stop-All.ps1
python -m unittest -v test_tunnel_guard
```

GitHub Actions 使用 Windows PowerShell 5.1 和 Python 运行离线测试，不需要服务器密钥或其他 secrets。CI 通过不代表所有 Linux/OpenSSH 组合均已通过真实连接验证。

`Test-Tunnel-Recovery.ps1` 是可选的真实故障注入工具，只有显式传入 `-Run` 才进行远端操作。使用独立、未占用的高端口和没有已有转发的 SSH 别名，并先运行不带 `-Run` 的预览；请阅读脚本参数与提示后执行。此测试不属于默认 CI。

```powershell
# 预览不读取 SSH 配置，也不连接远端
.\Test-Tunnel-Recovery.ps1 -Alias server-a -RemotePort 27997

# 主动执行故障注入；测试端口必须不同于配置中的生产端口
.\Test-Tunnel-Recovery.ps1 -SshConfig 'C:\ssh\config' -Alias server-a -RemotePort 27997 -Run
```

## 许可证

[MIT](LICENSE)。
