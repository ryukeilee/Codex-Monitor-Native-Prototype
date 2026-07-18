# Codex Monitor Native

一个面向 macOS 菜单栏的 Codex 额度监视器。它以原生 SwiftUI/AppKit 方式运行，常驻菜单栏，按服务端实际返回展示 5 小时、周、月及未知时长额度窗口和数据可信度信息；仓库同时包含一个 widget extension 工程用于扩展展示。

仓库当前重点不是继续堆功能，而是保持这几个行为稳定可验证：

- 菜单栏标题只显示周额度剩余百分比。
- Popover 与 Widget 通过同一展示投影呈现动态额度窗口、恢复时间和数据可信度信息。
- 真实数据刷新失败时保留上次成功快照，不把菜单栏直接清空。

## 当前用途

适合这几类场景：

- 自己在本机持续观察 Codex 额度变化。
- 快速确认当前显示的是最新真实数据，还是历史快照/演示数据。
- 在登录失效、网络异常或解析失败时，区分失败类型并决定是否需要手动处理。

当前仓库没有承诺以下能力：

- 不提供多账户管理。
- 不提供历史图表或长期趋势分析。
- 不提供后台服务安装器或自动更新。
- 不保证离线时仍能获取新数据；失败时只会保留上次成功结果。

## 运行要求

- macOS 14 或更高版本。
- 本机可执行 `swift build` / `swift test`。
- 本机可执行 `xcodebuild`，用于打包 widget extension。
- 若要读取真实额度，需要本机可用的 `codex` 可执行文件，并支持 `codex app-server`。

真实数据依赖说明：

- App 通过 `codex app-server` 的默认 stdio 传输发起 `account/rateLimits/read` 请求；不附加较新版本才支持的 `--stdio` 参数。
- 每次真实刷新都会重新发现候选：依次检查自定义 `CODEX_BIN`、`CODEX_EXECUTABLE`、GUI 进程的绝对 `PATH`、Homebrew、常见 npm/pnpm/Volta/NVM/fnm 位置，以及 Codex/ChatGPT App bundle。
- 候选必须是绝对路径、常规文件且可执行；符号链接会规范化并去重。某个自定义候选失效不会遮蔽后续可用候选，升级换址后无需重启 App。
- App 会逐个验证候选的 app-server 初始化与 `account/rateLimits/read` 能力；只在启动失败或确定不兼容时尝试下一个候选。
- 每次真实刷新都会在 RPC 前后读取同一 `CODEX_HOME/auth.json` 的账号与登录会话边界；持久化内容只有域分隔 SHA-256 指纹，不包含邮箱、token 或原始账号 ID。
- 只有当前账号与登录会话仍能确认属于该快照时，失败刷新才继续显示上次成功数据；退出登录、重新登录、切换账号或身份无法可靠确认时会清空旧真实快照并显示 `--%`。

## 菜单栏与 Popover

### 菜单栏显示策略

- 成功、刷新中、已过期、网络异常、需要登录、数据异常时：
  菜单栏只显示可信周额度百分比，例如 `71%`；没有可信周窗口时显示 `--%`。
- 尚无真实快照、空闲或演示模式时：
  菜单栏显示 `--%`，避免把演示数据误当成真实额度。

这意味着菜单栏是“最小状态面板”，只负责持续给出一个稳定的周额度数字，不会用 5 小时、月或未知窗口代替周额度。

### Popover 信息含义

Popover 里有三类关键信息：

- 顶部次要状态行：
  显示更新时间、最近尝试时间、数据来源和当前刷新状态。例如 `更新 今天 12:40 · 尝试 今天 12:48 · 真实数据 · 最新`。
- 真实链路诊断行：
  单独说明最近一次真实额度请求卡在哪一段，例如 `真实链路：Codex 可用，请求成功`、`真实链路：需要登录，显示上次成功数据`、`真实链路：响应不可解析，显示上次成功数据`。
- Quota Summary 主体：
  按 `5 小时 → 周 → 月` 的稳定顺序展示当前可信窗口；历史缓存、无效、不可用和语义未知窗口不会生成卡片。

兼容与容量规则：

- 服务端动态窗口缺少 5 小时或周窗口时，仅在对应 legacy 字段为当前实时值时补入兼容项；同语义的已知窗口只保留 canonical 来源，无效、缓存、未知和演示值不会进入额度卡片。
- Popover 使用两列网格；窗口超过两行时进入有高度上限的可滚动视口，刷新期间窗口集合变化也会重新测量面板。
- Widget 小尺寸确定性选择一个可信 primary 窗口，中尺寸最多展示三个窗口；未显示的窗口用 `+N` 明确提示。只有月窗口或只有未知窗口时，该窗口本身仍会显示，不会伪装成 5 小时或周额度。

当前状态文案含义：

- `真实数据 · 最新`：最近一次真实刷新成功，且数据仍在有效窗口内。
- `真实数据 · 已过期`：仍在显示上次真实快照，但该快照距离成功刷新已超过陈旧阈值。
- `真实数据 · 网络异常`：本次刷新请求失败，且已确认仍是同一账号会话，因此保留上次真实快照。
- `需要登录`：Codex 登录态或授权不可用；旧会话快照会失效，不再作为当前真实数据展示。
- `真实数据 · 数据异常`：收到了不可用响应；仅在账号会话归属仍一致时保留上次真实快照。
- `演示数据 · 演示模式`：当前不是实时额度结果，而是 mock 数据。
- `演示数据 · 未连接`：尚未拿到可用真实快照。

真实链路诊断文案含义：

- `真实链路：Codex 可用，请求成功`：最近一次真实请求完整成功。
- `真实链路：未找到 codex 可执行文件...`：本机未解析到可执行的 `codex`。
- `真实链路：Codex 不可用...`：`codex` 存在，但启动、握手或进程生命周期异常。
- `真实链路：需要登录...`：RPC 返回认证/登录相关失败。
- `真实链路：请求超时...`：真实请求在超时时间内未完成。
- `真实链路：响应不可解析...`：拿到响应，但结构不符合可用额度数据要求。
- `真实链路：RPC 请求失败...`：请求发出后被 RPC 层拒绝或返回了非认证类错误。

带有 `显示上次成功数据` 的文案表示：

- 当前菜单栏和 Popover 仍在展示最近一次成功的真实快照。
- 当前账号与登录会话仍和该快照的归属一致，因此这次非身份类失败没有清空缓存。

`更新 ... · 尝试 ...` 的规则：

- 最近成功时间和最近尝试时间一致时，只显示一次 `更新`。
- 两者不一致时，会保留 `尝试`，方便判断“当前显示的是历史成功快照，但刚刚刷新失败了”。

## 刷新与失败处理

当前已实现的刷新策略：

- App 启动约 1 秒后会触发一次刷新。
- 默认定时刷新间隔为 5 分钟。
- 连续失败后会退避到 10 分钟、15 分钟。
- 系统唤醒后会恢复调度，并在短延迟后再刷新一次。
- Popover 中点击“刷新”会触发手动刷新。

失败处理原则：

- 不因单次失败清空菜单栏数字。
- 如果本地有上次成功的真实快照，就继续显示该快照。
- 错误状态只改变状态文案、tooltip 和 Popover 说明，不改动已缓存的最后一次真实额度。

## 构建、运行与安装

主应用是 Swift Package，可直接用 SwiftPM 构建；仓库另外提交了 `CodexMonitorWidgetExtension.xcodeproj`，供打包脚本构建 widget extension。

### 构建

```bash
swift build -c debug
swift build -c release
```

### 测试

```bash
swift test
```

### 本地运行

```bash
./script/build_and_run.sh
```

说明：

- 脚本会先构建 SwiftPM 主应用，再在工程存在时构建 `CodexMonitorWidgetExtension`。
- 脚本会在 `dist/` 里重新生成 `.app`，注入 entitlements，并做本地 codesign 后启动。

常用变体：

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
BUILD_CONFIGURATION=release ./script/build_and_run.sh
```

`--verify` 是本机安装验收的唯一入口：它会构建主应用和 Widget，先在安装目录旁创建唯一 staging 并校验版本、主应用与 Widget 签名及预期 App Group entitlements，再关闭旧实例并以可回滚 backup 覆盖安装。只有启动、运行路径、版本、`pluginkit` Widget 路径及跨副本验收全部通过后才删除 backup；中途失败会恢复原安装，并在原安装此前正在运行时尽可能重新启动。回滚前必须以可判错的 `pgrep`/`ps` 门禁证明所有验收进程均已退出；枚举、身份查询或 TERM/KILL 收敛失败时禁止移动当前 target 或恢复旧 App，并保留当前安装、唯一 backup 与受控工作目录。如果回滚本身因权限或文件系统错误无法完成，脚本同样不会删除唯一 backup，而会输出精确人工恢复路径。它还会验证三段顺序：安装版 owner 拒绝带开发绕过的直接 challenger、已运行的开发 owner 向首选安装移交、无开发绕过的旧 `dist` 副本用关联 token 重定向到首选安装。

`INSTALL_APP_PATH` 必须是规范化绝对路径，最终名称精确为 `CodexMonitorNative.app`；脚本拒绝根目录、用户主目录、仓库根、普通目录、其他 Bundle ID、目标别名以及无法安全解析的父路径。安装目录不可写时，可用 `INSTALL_APP_PATH="$HOME/Applications/CodexMonitorNative.app"` 指定用户目录。默认 `CODESIGN_IDENTITY=-` 使用本机 ad-hoc 签名；这只证明本地产物完整性及已签入的 entitlements，不等于证书/描述文件有效，也不证明 WidgetKit 已实际加载 extension。实际运行路径由脚本的 `ps`、唯一进程和 owner record 门禁证明。需要证书签名时应显式传入唯一的 `CODESIGN_IDENTITY`，并另查 provisioning 与系统运行日志。

### 手动指定安装路径

```bash
BUILD_CONFIGURATION=release ./script/build_and_run.sh --verify
INSTALL_APP_PATH="$HOME/Applications/CodexMonitorNative.app" ./script/build_and_run.sh --verify
```

安装路径负向门禁可在不触发构建的情况下执行；以下命令只清理自己创建的临时目录：

```bash
path_safety_root="$(mktemp -d /tmp/codex-monitor-path-safety.XXXXXX)"
cleanup_path_safety() { rm -rf "$path_safety_root"; }
trap cleanup_path_safety EXIT
mkdir "$path_safety_root/CodexMonitorNative.app"
touch "$path_safety_root/sentinel" "$path_safety_root/CodexMonitorNative.app/sentinel"
for unsafe_path in \
  /CodexMonitorNative.app \
  "$HOME/CodexMonitorNative.app" \
  "$PWD/CodexMonitorNative.app" \
  "$path_safety_root/CodexMonitorNative.app"; do
  if INSTALL_APP_PATH="$unsafe_path" ./script/build_and_run.sh --verify; then
    echo "危险路径被错误接受：$unsafe_path" >&2
    exit 1
  fi
done
test -f "$path_safety_root/sentinel"
test -f "$path_safety_root/CodexMonitorNative.app/sentinel"
```

完整替换流程可先隔离到临时父目录；这仍会构建、启动 App 并更新本机 Widget 注册，只是不会替换 `/Applications` 中的安装包：

```bash
isolated_install_root="$(mktemp -d /tmp/codex-monitor-install.XXXXXX)"
cleanup_isolated_install() { rm -rf "$isolated_install_root"; }
trap cleanup_isolated_install EXIT
INSTALL_APP_PATH="$isolated_install_root/CodexMonitorNative.app" ./script/build_and_run.sh --verify
```

### 手动验证真实/失败路径

如果你只想验证 UI 行为而不等待真实请求，可使用仓库现有强制路径：

```bash
CODEX_MONITOR_FORCE_REFRESH_SUCCESS=1 ./script/build_and_run.sh
CODEX_MONITOR_FORCE_REFRESH_FAILURE=1 ./script/build_and_run.sh
```

适合检查：

- 菜单栏是否继续保留周额度或 `--%`
- Popover 顶部是否显示更新时间、尝试时间、数据来源、刷新状态和真实链路诊断
- 失败时是否保留上次成功快照

## 当前可验证状态

截至当前仓库状态，可以直接从代码和测试中验证这些事实：

- 菜单栏标题只显示可信周额度，不会以 5 小时、月或未知窗口替代；无可信周窗口时显示 `--%`。
- Popover、tooltip 与 Widget 共用动态窗口投影，覆盖 only-weekly、only-monthly、已知三窗口，以及未知、重复来源、缓存和无效值过滤路径。
- Popover 动态行数变化会触发尺寸更新，超过两行时提供可滚动视口。
- Widget 小/中尺寸分别使用容量 1/3 的确定性选择规则，并用 `+N` 显示溢出数量。
- Popover 会显示更新时间、最近尝试时间、数据来源、刷新状态与真实链路健康状态。
- `networkFailed`、`authRequired`、`parseFailed` 会显示成不同中文状态，而不是统一的“失败”。
- 非身份类失败仅在账号与登录会话归属仍可确认时保留最近一次成功快照；登出、重登、账号切换和身份不可确认会安全降级为无真实快照。
- 手动刷新入口存在于 Popover，刷新时会保留当前真实快照直到新结果返回。
- 启动后自动刷新、定时刷新、失败退避和唤醒后刷新都有代码与测试覆盖。
- widget 展示桥接和布局相关逻辑有独立测试覆盖。

对应补充文档：

- [VERIFICATION.md](VERIFICATION.md)
- [QA_CHECKLIST.md](QA_CHECKLIST.md)

说明：

- `VERIFICATION.md` 和 `QA_CHECKLIST.md` 记录了额外的验证路径，但其中个别历史表述可能早于当前测试数量；以当前代码和本地命令结果为准。

## 仓库卫生

- 不要把密钥或登录信息提交到仓库。
- 推送前按需使用 `.gitleaks.toml` 的规则做泄漏检查。
- 凭据优先放环境变量或本地私有配置。
