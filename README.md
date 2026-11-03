# Logi Options+ 一键精简工具  v2.2

> 把罗技 Logi Options+ 从 **3.05 GB 压到约 0.5 GB**，只保留鼠标基础功能。
> 不改动主程序签名 —— 软件正常打开，辅助功能/输入监控/蓝牙权限不会失效。
>

> - **v2.2** 新增 **Intel(x86_64) 冗余架构瘦身**（默认开启，`--no-thin` 关闭），
>   做法与 Pearcleaner 一致：只 `lipo` 瘦身、**完全不重新签名**，因此权限不受影响。

---

## 一、怎么用

| 想做的事 | 操作 |
|---|---|
| **正式精简 / 修复界面报错** | 双击 `一键精简Logi.command`，输入 Mac 登录密码，等它跑完 |
| **先看看会删什么** | 终端执行 `bash "/Applications/Logi-Slim/一键精简Logi.command" --dry-run` |
| **体检（自检 9 项 + 组件 + 架构）** | `bash ".../一键精简Logi.command" --check`，**不需要密码** |
| **软件更新后再次精简** | 再双击一次即可（可重复运行，自动适配新版本号） |
| **不做架构瘦身** | `bash ".../一键精简Logi.command" --no-thin` |
| **把删掉的功能装回来** | `bash ".../一键精简Logi.command" --restore`，或重装 Options+ |
| **不要自动打开软件** | 加上 `--no-launch` |

第一次运行后，脚本会自动在**桌面**放一个同名副本，以后双击桌面那个即可。

---

## 一之二、Intel(x86_64) 架构瘦身（v2.2 新增）

| 项目 | 说明 |
|---|---|
| 做什么 | 找出 bundle 里所有「x86_64 + arm64 双架构」的 Mach-O，`lipo -thin arm64` 原地瘦身 |
| 覆盖范围 | `logioptionsplus.app` 主程序 + `logioptionsplus_agent.app` 后台服务（含其内置 updater） |
| 收益 | 更新后主程序约 190 MB + 后台服务约 130 MB |
| **不重签名** | 这是关键。实测重签名会因 hardened runtime 的库验证而启动失败（`dyld: different Team IDs`）；不签名时外层仍是 Logitech 官方签名，**系统权限不会失效** |
| 安全机制 | 只备份"真正会被改动的文件" → 瘦身 → 重启后台服务 + 打开主程序验证 → **任一验证失败自动回滚**；全部通过后立即删除备份，净收益不缩水 |
| 刻意不动 | `Logi Options+ Driver Installer.bundle`（内含系统扩展，动它有风险，且只有 2.8 MB） |
| 每次更新后 | Logitech 会把双架构装回来 —— 重跑一次脚本即可（`--check` 会提示"还有 N 个双架构文件"） |

> 已在本机用 agent 的真实副本做过完整演练：268 MB → 134 MB（省 141 MB），12 个文件；
> 回滚后架构恢复 `x86_64 arm64`、体积还原 268 MB。

---

## 二、根因：软件启动时会做 9 项完整性自检

界面的「正在获取资源 → × 缺少一些必需文件」不是猜测，而是 App 主进程里
`utils/installationIntegrity` 这段代码的判定结果（未混淆的 `main.js` 里可读）：

```js
files    = ["current.json", "groups.json", "installation.json"]  // 必须存在
dirs     = ["depots", "cache"]                                    // 必须存在且「非空」
launchables = [ "…/logioptionsplus_agent.app",
                "…/logioptionsplus_updater.app",
                "/Library/LaunchDaemons/com.logi.optionsplus.updater.plist",
                "/Library/LaunchAgents/com.logi.optionsplus.plist" ]

function dirNonEmpty(p){
  return fs.existsSync(p) && fs.statSync(p).isDirectory() && fs.readdirSync(p).length > 0
}
```

**只要 `cache` 目录被整个删掉，自检就不过**，于是：

- 界面卡在「正在获取资源 × 缺少一些必需文件」（问题 2）
- 同时触发后台自动修复 → 重新下载安装包与组件（**这才是"重启后又下载回来"的真正原因**，问题 1）

> v1.0 为了省 1.32 GB 把整个 `cache` 目录删了 —— 这是致命错误。
> v2.1 改为：**只删 `cache` 里 ≥10 MB 的大归档，保留小缓存文件让目录保持非空。**
> 真正的大头（主程序 811 MB / 语音 321 MB / 插件 124 MB）依然全部释放，
> 只多保留约 14 MB。若目录为空，脚本会自动写入一个 `.slim-placeholder` 占位文件。

---

## 三、保留 / 删除清单

### ✅ 完整保留（鼠标基础功能所需 + 通过自检所需）
- `logioptionsplus.app` 主程序（官方签名一行没动）
- `logioptionsplus_agent.app` 后台设备管理服务 + `logioptionsplus_updater.app`
- **`cache` 目录（非空）与 `depots` 目录（非空）** —— 自检硬性要求
- 你的全部配置：`settings.db`、`macros.db`、`permissions.json`
- 设备数据库、设备/资源 depot、`card_presets` 卡片预设
- 开机代理 `com.logi.optionsplus.plist`、`com.logi.optionsplus.updater.plist`

### ❌ 删除内容（约 2.2 GB）

| 内容 | 大小 | 说明 |
|---|---|---|
| `cache/` 里 ≥10MB 的大归档 | **约 1.31 GB** | 主程序 811MB + 语音 321MB + 插件 124MB 等下载缓存 |
| `LogiPluginService.app` | **346 MB** | 第三方插件服务 + Mono 运行时（Adobe / Teams / Zoom） |
| `logioptionsplus_logivoice.app` | **323 MB** | LogiVoice AI 语音输入 |
| `LogiRightSightForWebcams/` | **69 MB** | RightSight 摄像头自动取景 |
| `Plugins/`（ExManCmd 等） | **35 MB** | Adobe 插件载荷 |
| `logi_ai_portal.app` | **28 MB** | Logi AI Prompt Builder |
| 各组件 depot 载荷 | **187 MB** | 上述组件的安装包解压体 |
| 插件服务数据 + 图标/GPU 缓存 | **24 MB** | `LogiPluginService/`、`icon_cache`、Chromium 缓存 |
| 系统 pkg 收据 | 极小 | `LogiRightSightForWebcams.pkg`、`pluginservice.package` |

同时删除 2 个开机代理文件本身：`com.logi.optionsplus.logivoice.plist`、
`com.logitech.LogiRightSight.Agent.plist`（**只卸载不删文件是没用的，重启会被拉起来**）。

---

## 四、四道"防复活"措施

| # | 措施 | 为什么 |
|---|---|---|
| ★ | **`cache` 只删大归档、保留小缓存** | 让完整性自检通过。自检不过 → 报错 + 自动重装修复，两个问题同源 |
| 1 | **改写 `features_config/features.json`**：把 LogiVoice / AI Portal 两个官方配置的条件改成永不成立，并新增一条 `Slim - 停用非鼠标组件` 规则覆盖其余 11 个 depot | 官方就是靠"条件不成立的 `conditionalDepots` 进入 `builds/<id>.filter.json` 的 `filtered` 名单"来排除组件的（`predefined_profiles`、`system_actions` 就是这么被排除的，它们同样是 `required: true`）。v1.0 **删掉整个配置**是搞反了：删掉配置后组件不再被过滤，反而变成必须安装 |
| 2 | **修剪 `installation.json`**：删掉指向已删文件的 1062 条记录 | 保持安装记录与实际一致（不影响启动自检，自检只查上面那 9 项） |
| 3 | **删除系统 pkg 收据** | 不删的话系统与后台仍认为 RightSight / 插件服务"已安装" |
| 4 | **关闭自动检查更新与自动下载**（`periodic_check.json`） | 减少后台自行拉取的机会；想更新时在界面里手动检查，或把这两项改回 `true` |

改写前所有涉及的状态文件都会备份到
`/Library/Application Support/Logi/LogiOptionsPlus/.slim_backup/<时间戳>/`，
`--restore` 可一键还原。

---

## 五、验证流程

1. 双击运行脚本（会要求密码）；
2. 脚本结束前会打印**完整性自检 9 项**，应全部为 ✓，并显示
   「界面不会再卡在『缺少一些必需文件』」；
3. 打开 Options+，确认能进鼠标设置页；
4. 想再确认一次：`bash ".../一键精简Logi.command" --check`（不需要密码），
   它会报告自检 9 项、组件有没有回来、过滤名单是否生效、**还有没有 Intel 冗余架构**。

---

## 六、实测记录

- 系统 macOS 27.0.1 (arm64)，Options+ 2.8.981479 (build 876307)
- 精简前 3.05 GB → 组件/缓存精简后 0.84 GB → 架构瘦身后约 **0.5 GB**
- 根因来自 `app.asar` 内未混淆的 `main.js`：`CHECK_INSTALLATION_INTEGRITY`
  → `require(4581).checkInstallationIntegrity`，逐行核对过 9 项检查
- 现场诊断：9 项里**只有 `cache` 目录不合格**，其余 8 项全部通过 —— 与界面报错完全吻合
- `slim_cache` 已用两组夹具实测：① 大+小文件混合 → 大归档删除、小缓存保留、目录非空；
  ② 目录完全不存在 → 自动创建并写入占位文件
- 架构瘦身：**不重签名**的做法已实测可用于启动（主程序瘦身后主进程 + GPU/网络/渲染
  子进程全部存活、无崩溃报告）；重签名的做法实测失败（`dyld: different Team IDs`）
- 瘦身+回滚机制已用 agent 的真实副本演练：268 MB → 134 MB（省 141 MB，12 个文件），
  回滚后恢复 `x86_64 arm64` 与 268 MB
- 改写逻辑已验证 **幂等**（连续两次结果一致）且输出均为合法 JSON

---

## 七、遇到「logioptionsplus 因为出现问题而无法打开…你可能需要重新安装该应用程序」

**这不是软件坏了，先不要重装。** 这是 macOS 的 LaunchServices 数据库里存了
**指向已失效路径的注册记录**，系统按软件 ID 找不到程序。

一条命令修复：

```bash
"/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister" \
  -f -R -trusted /Applications/logioptionsplus.app
```

> ⚠️ 不要为了测试把 `logioptionsplus.app` 复制到别处再启动：副本会用同一个软件 ID
> 注册新路径，删掉副本后就会留下这种失效记录。脚本已在最后一步内置自动刷新注册。

---

## 七、遇到「logioptionsplus 因为出现问题而无法打开…你可能需要重新安装该应用程序」

**这不是软件坏了，先不要重装。** 这是 macOS 的 LaunchServices 数据库里存了
**指向已失效路径的注册记录**，系统按软件 ID 找不到程序。

一条命令修复：

```bash
"/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister" \
  -f -R -trusted /Applications/logioptionsplus.app
```

> ⚠️ 不要为了测试把 `logioptionsplus.app` 复制到别处再启动：副本会用同一个软件 ID
> 注册新路径，删掉副本后就会留下这种失效记录。脚本已在最后一步内置自动刷新注册。
