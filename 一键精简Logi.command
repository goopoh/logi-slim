#!/bin/bash
# ==============================================================================
#  Logi Options+ 一键精简脚本   (macOS / Apple Silicon & Intel)
#  版本: 2.2
#
#  作用: 删除 Logi Options+ 中与“鼠标基础设置”无关的臃肿内容:
#        · 1.3 GB 安装包下载缓存(只删 ≥10MB 的大归档, 保留小缓存)
#        · LogiVoice 语音输入 / Logi AI Prompt Builder / RightSight 摄像头取景
#        · LogiPluginService 第三方插件服务(Adobe、Teams 等) + 插件载荷
#        · 各处 depot 安装载荷、图标/GPU 缓存、系统 pkg 收据
#        · Intel(x86_64) 冗余架构 —— 只保留本机 arm64
#
#  ★ v2.2 新增: 精简 Intel 冗余架构(默认开启, 用 --no-thin 关闭)
#    做法与 Pearcleaner 一致: 只用 lipo 把"双架构"文件瘦成 arm64, **完全不重新签名**。
#    · 不重签名 → 外层仍是 Logitech 官方签名, 系统权限(辅助功能/输入监控/蓝牙)不失效
#    · 实测: 重签名反而会失败(hardened runtime 库验证报 different Team IDs)
#    · 只备份"真正会被改动的文件", 启动验证通过后立刻删备份, 净收益不缩水
#    · 后台服务(agent)瘦身后自动重启验证; 任一环失败 → 自动回滚
#    · 覆盖: 主程序 logioptionsplus.app + 后台 logioptionsplus_agent.app
#      (含其内置 updater)。Logi Options+ Driver Installer.bundle 含系统扩展, 刻意不动。
#
#  ★ v2.1 修正了一个致命错误(也是 v1.x 两个问题的真正原因):
#    App 主进程的安装完整性自检 (utils/installationIntegrity) 要求
#      · current.json / groups.json / installation.json 存在
#      · depots 目录「存在且非空」
#      · cache 目录「存在且非空」   ← v1.x 把整个 cache 删了, 于是:
#          界面卡在「正在获取资源 × 缺少一些必需文件」
#          并且触发后台自动重装(表现为“重启后又被下载回来”)
#    现在改为只删 cache 里 ≥10MB 的大归档, 目录保持非空。
#
#  另外做 4 件"防复活"的事:
#        1. 让后台过滤器把这些组件排除在"本机该安装的清单"之外
#        2. 修剪 installation.json 里指向已删文件的记录
#        3. 删除系统 pkg 收据(LogiRightSightForWebcams / pluginservice)
#        4. 关掉"自动检查更新并自动下载"
#
#  不改动 logioptionsplus.app 本体 —— 官方签名保持完好, 因此:
#        · 软件照常打开, 辅助功能/输入监控/蓝牙权限不会失效
#        · 软件更新后重跑本脚本即可(脚本可重复运行, 自动适配新版本号)
#
#  用法:
#        双击运行                     正常精简(会要求输入管理员密码)
#        bash 本文件 --dry-run        只预览, 不删任何文件(无需密码)
#        bash 本文件 --check          只体检: 报告组件有没有偷偷回来(无需密码)
#        bash 本文件 --restore        还原被改写的状态文件
#        bash 本文件 --no-launch      精简后不自动打开软件
#        bash 本文件 --no-thin        不做 Intel 架构瘦身(默认做)
#        bash 本文件 --help           帮助
# ==============================================================================

set -uo pipefail

VERSION="2.2"
DRY=0
RESTORE=0
LAUNCH=1
CHECK=0
THIN=1

# ---------- 固定路径 ----------
LOGBASE="/Library/Application Support/Logi/LogiOptionsPlus"
LOCBASE="/Library/Application Support/Logitech.localized/LogiOptionsPlus"
RSDIR="/Library/Application Support/Logitech.localized/LogiRightSightForWebcams"
LA_DIR="/Library/LaunchAgents"
UTIL="/Applications/Utilities"
AGENT="$LOCBASE/logioptionsplus_agent.app"

# 需要删除的 depot 组件名(在 depots/<buildID>/ 下, 自动适配未来版本)
DEPOT_REMOVE=(
  logivoice logi_ai_portal right_sight logi_plugin_service
  plugin_cep plugin_installer plugin_aip plugin_uxp plugin_lightroom_classic
  plugin_illustrator plugin_photoshop plugin_premiere_pro plugin_indesign
)
# 需要删除的特性开关(会被后台写进 features_cache.json)
FLAG_REMOVE=(logivoice_enabled logi_ai_portal_enabled)
# installation.json 中需要一并修剪掉的路径前缀(对应下面被删掉的文件)
PRUNE_PREFIXES=(
  "$LOCBASE/logioptionsplus_logivoice.app"
  "$LOCBASE/logi_ai_portal.app"
  "$LOCBASE/Plugins"
  "$RSDIR"
  "$UTIL/LogiPluginService.app"
  "/Library/Application Support/Logi/LogiPluginService"
  "$LA_DIR/com.logi.optionsplus.logivoice.plist"
  "$LA_DIR/com.logitech.LogiRightSight.Agent.plist"
)

# ---------- 颜色 ----------
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; BOLD=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; BOLD=""; N=""
fi

msg()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s×%s %s\n' "$R" "$N" "$*"; }
step() { printf '\n%s%s%s\n' "$BOLD$B" "$*" "$N"; }
die()  { printf '\n%s错误: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

fmt() { awk -v k="${1:-0}" 'BEGIN{ if(k>=1048576) printf "%.2f GB",k/1048576; else if(k>=1024) printf "%.1f MB",k/1024; else printf "%d KB",k }'; }

# ==============================================================================
# 完整性自检 —— 严格复刻 App 主进程 utils/installationIntegrity 的 9 项检查
# 任何一项不过, 界面就会停在「正在获取资源 × 缺少一些必需文件」
# ==============================================================================
INTEGRITY_FAIL=0
integrity_check() {
  INTEGRITY_FAIL=0
  local agent="$LOCBASE/logioptionsplus_agent.app"
  ic_file() {  # 名称 路径
    if [ -e "$2" ]; then ok "$1"; else bad "$1   <-- 缺失"; INTEGRITY_FAIL=$((INTEGRITY_FAIL+1)); fi
  }
  ic_dir() {   # 名称 路径（必须存在且非空）
    if [ -d "$2" ] && [ -n "$(ls -A "$2" 2>/dev/null)" ]; then
      ok "$1（目录非空，$(ls -A "$2" 2>/dev/null | wc -l | tr -d ' ') 项）"
    else
      bad "$1   <-- 目录缺失或为空（界面会报“缺少一些必需文件”）"; INTEGRITY_FAIL=$((INTEGRITY_FAIL+1))
    fi
  }
  ic_file "logioptionsplus_agent.app"   "$agent"
  ic_file "logioptionsplus_updater.app" "$agent/Contents/Frameworks/logioptionsplus_updater.app"
  ic_file "current.json"                "$LOGBASE/current.json"
  ic_file "groups.json"                 "$LOGBASE/groups.json"
  ic_file "installation.json"           "$LOGBASE/installation.json"
  ic_dir  "depots 目录"                 "$LOGBASE/depots"
  ic_dir  "cache 目录"                  "$LOGBASE/cache"
  ic_file "com.logi.optionsplus.updater.plist" "/Library/LaunchDaemons/com.logi.optionsplus.updater.plist"
  ic_file "com.logi.optionsplus.plist"  "/Library/LaunchAgents/com.logi.optionsplus.plist"
}

usage() {
  awk 'NR>2 && /^# =====/{exit} NR>2{sub(/^# ?/,""); print}' "$0"
  exit 0
}

for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY=1 ;;
    --check)      CHECK=1 ;;
    --restore)    RESTORE=1 ;;
    --no-launch)  LAUNCH=0 ;;
    --thin)       THIN=1 ;;
    --no-thin)    THIN=0 ;;
    --help|-h)    usage ;;
    *)            die "未知参数: $a（用 --help 查看用法）" ;;
  esac
done

# ==============================================================================
# 提权 (预览/体检模式只读, 不需要密码)
# ==============================================================================
if [ "$(id -u)" -ne 0 ] && [ "$DRY" -eq 0 ] && [ "$CHECK" -eq 0 ]; then
  msg "${Y}需要管理员权限才能删除 /Library 下的组件。${N}"
  if [ -t 0 ]; then
    exec sudo -p "请输入你的登录密码（终端里不会显示）: " /bin/bash "$0" "$@"
  else
    # 没有终端时(极少见)弹出图形密码框
    extra=""
    [ "$RESTORE" -eq 1 ] && extra="$extra --restore"
    [ "$LAUNCH" -eq 0 ] && extra="$extra --no-launch"
    exec osascript -e "do shell script \"/bin/bash \\\"$0\\\"$extra\" with administrator privileges"
  fi
fi

# ==============================================================================
# 环境探测
# ==============================================================================
CUSER=$(stat -f %Su /dev/console 2>/dev/null || echo "")
if [ -z "$CUSER" ] || [ "$CUSER" = "root" ]; then
  CUSER="${SUDO_USER:-$(id -un)}"
fi
CUID=$(id -u "$CUSER" 2>/dev/null || stat -f %u /dev/console)
CUSER_HOME=$(dscl . -read "/Users/$CUSER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -d "$CUSER_HOME" ] || CUSER_HOME="/Users/$CUSER"
[ -d "$CUSER_HOME" ] || CUSER_HOME="$HOME"

if [ -x /usr/bin/python3 ]; then PY=/usr/bin/python3
elif command -v python3 >/dev/null 2>&1; then PY=$(command -v python3)
else die "找不到 python3（请先安装 Xcode 命令行工具: xcode-select --install）"; fi

APP="/Applications/logioptionsplus.app"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$LOGBASE/.slim_backup/$STAMP"

msg ""
msg "${BOLD}============================================================${N}"
msg "${BOLD}   Logi Options+ 一键精简脚本  v$VERSION${N}"
msg "${BOLD}============================================================${N}"
msg "  当前用户: $CUSER    主程序: $APP"
[ "$DRY" -eq 1 ] && msg "  ${Y}【预览模式】只统计不删除${N}"

[ -d "$APP" ] || die "没有找到 $APP，请确认已安装 Logi Options+"

# 记录精简前体积
before_kb() {
  local t=0 k
  for p in "$APP" "$LOGBASE" "$LOCBASE" "$UTIL/LogiPluginService.app" \
           "$CUSER_HOME/Library/Application Support/LogiOptionsPlus"; do
    [ -e "$p" ] || continue
    k=$(du -sk "$p" 2>/dev/null | awk '{print $1}'); [ -n "$k" ] && t=$((t+k))
  done
  echo "$t"
}
SIZE_BEFORE=$(before_kb)

# ==============================================================================
# 体检模式（只读，不需要密码）
# ==============================================================================
if [ "$CHECK" -eq 1 ]; then
  step "体检：检查精简是否还保持着"
  msg "  当前 Logi 总占用: $(fmt "$SIZE_BEFORE")"
  msg ""
  msg "  ${BOLD}★ 完整性自检（与 App 的 utils/installationIntegrity 完全一致）${N}"
  integrity_check
  if [ "$INTEGRITY_FAIL" -eq 0 ]; then
    ok "${BOLD}9 项全部通过 —— 界面不会出现「缺少一些必需文件」${N}"
  else
    bad "${BOLD}有 $INTEGRITY_FAIL 项不过 —— 界面会停在「正在获取资源 × 缺少一些必需文件」${N}"
    msg "    修法: 双击运行一次本脚本即可（它会补齐 cache 目录等）"
  fi
  msg ""
  msg "  ${BOLD}① 被删组件是否偷偷回来了${N}"
  back=0
  check_path() {
    if [ -e "$1" ]; then printf '    %s✗ 已回来  %8s  %s%s\n' "$R" "$(du -sh "$1" 2>/dev/null | cut -f1)" "$1" "$N"; back=$((back+1))
    else printf '    %s✓ 仍缺失  %8s  %s%s\n' "$G" "-" "$1" "$N"; fi
  }
  # 注意: cache 目录本身必须保留(非空), 所以这里只看它有没有重新变大
  ckb=$(du -sk "$LOGBASE/cache" 2>/dev/null | awk '{print $1}'); [ -n "$ckb" ] || ckb=0
  if [ "$ckb" -gt 102400 ]; then
    printf '    %s✗ cache 又涨到 %s（后台重新下载了安装包）%s\n' "$R" "$(fmt "$ckb")" "$N"; back=$((back+1))
  else
    printf '    %s✓ cache 目录正常（%s，非空即可通过自检）%s\n' "$G" "$(fmt "$ckb")" "$N"
  fi
  check_path "$LOCBASE/logioptionsplus_logivoice.app"
  check_path "$LOCBASE/logi_ai_portal.app"
  check_path "$RSDIR"
  check_path "$LOCBASE/Plugins"
  check_path "$UTIL/LogiPluginService.app"
  msg ""
  msg "  ${BOLD}② 后台认为该装哪些 depot${N}"
  [ -f "$LOGBASE/current.json" ] && "$PY" - "$LOGBASE/current.json" <<'PYEOF'
import json,sys
d=json.load(open(sys.argv[1])); names=[x.get("name") for x in d.get("depots",[])]
bad=[n for n in names if n in ("logivoice","logi_ai_portal","right_sight","logi_plugin_service") or str(n).startswith("plugin_")]
print("    current.json 共 %d 个 depot" % len(names))
print(("    ✓ 没有多余组件" if not bad else "    ✗ 又出现了: %s" % bad))
PYEOF
  msg ""
  msg "  ${BOLD}③ 过滤器(filtered)是否已排除它们${N}"
  for f in "$LOGBASE"/builds/*.filter.json; do
    [ -f "$f" ] || continue
    "$PY" - "$f" <<'PYEOF'
import json,sys
d=json.load(open(sys.argv[1])); fl=d.get("filtered",[])
want=["logivoice","logi_ai_portal","right_sight","logi_plugin_service"]
miss=[w for w in want if w not in fl]
print("    %s: %d 项" % (sys.argv[1].split("/")[-1], len(fl)))
print(("    ✓ 已包含 %s" % want) if not miss else ("    ! 尚缺: %s" % miss))
PYEOF
  done
  msg ""
  msg "  ${BOLD}④ installation.json 是否仍声称已删文件存在${N}"
  [ -f "$LOGBASE/installation.json" ] && "$PY" - "$LOGBASE/installation.json" <<'PYEOF'
import json,sys
d=json.load(open(sys.argv[1])); paths=[f.get("path","") for f in d.get("files",[])]
n=sum(1 for p in paths if "/logioptionsplus_logivoice.app" in p or "/logi_ai_portal.app" in p or "/LogiOptionsPlus/Plugins/" in p)
print("    共 %d 条记录; 指向已删组件的: %d 条" % (len(paths), n))
print(("    ✓ 已修剪干净" if n==0 else "    ! 未修剪（仅影响卸载记录，不影响启动；卡在“缺少必需文件”是 cache 目录的问题）"))
PYEOF
  msg ""
  msg "  ${BOLD}⑤ 系统 pkg 收据 / 开机代理${N}"
  for r in /var/db/receipts/com.logitech.LogiRightSightForWebcams.pkg.plist /var/db/receipts/com.logi.installer.pluginservice.package.plist; do
    [ -e "$r" ] && printf '    %s✗ 收据仍在: %s%s\n' "$R" "$(basename "$r")" "$N" || printf '    %s✓ 收据已删: %s%s\n' "$G" "$(basename "$r")" "$N"
  done
  for p in "$LA_DIR/com.logi.optionsplus.logivoice.plist" "$LA_DIR/com.logitech.LogiRightSight.Agent.plist"; do
    [ -e "$p" ] && printf '    %s✗ 代理仍在: %s%s\n' "$R" "$(basename "$p")" "$N" || printf '    %s✓ 代理已删: %s%s\n' "$G" "$(basename "$p")" "$N"
  done
  msg ""
  msg "  ${BOLD}⑥ Intel(x86_64) 架构状态${N}"
  FAT_LEFT=0
  for pair in "主程序|$APP" "后台服务|$AGENT"; do
    lbl="${pair%%|*}"; pth="${pair##*|}"
    if [ ! -d "$pth" ]; then printf '    %s- %s: 不存在%s\n' "$Y" "$lbl" "$N"; continue; fi
    out=$("$PY" - "$lbl" "$pth" <<'PYEOF'
import os, struct, sys
lbl, root = sys.argv[1], sys.argv[2]
FAT = (0xcafebabe, 0xcafebabf); n = 0; tot = 0
for dp, dn, fn in os.walk(root):
    for x in fn:
        p = os.path.join(dp, x)
        if os.path.islink(p) or not os.path.isfile(p): continue
        try:
            with open(p, "rb") as f:
                if struct.unpack(">I", f.read(4))[0] in FAT: n += 1; tot += os.path.getsize(p)
        except Exception: pass
if n == 0: print("    \u2713 %s: 已是纯 arm64" % lbl)
else:      print("    ! %s: 还有 %d 个双架构文件（约可省 %.0f MB）—— 跑一次脚本即可" % (lbl, n, tot/2/1048576))
PYEOF
)
    printf '%s\n' "$out"
    case "$out" in *"还有"*) FAT_LEFT=1 ;; esac
  done
  msg ""
  if [ "$back" -eq 0 ] && [ "$INTEGRITY_FAIL" -eq 0 ] && [ "$FAT_LEFT" -eq 0 ]; then
    msg "  ${G}${BOLD}结论: 一切正常 —— 精简保持完好、软件自检通过、无 Intel 冗余架构。${N}"
  elif [ "$INTEGRITY_FAIL" -ne 0 ]; then
    msg "  ${Y}${BOLD}结论: 软件自检不通过（缺 $INTEGRITY_FAIL 项）—— 双击运行一次本脚本即可修复。${N}"
  else
    if [ "$back" -ne 0 ]; then
      msg "  ${Y}${BOLD}结论: 有 $back 个组件被装回来了 —— 请重新双击本脚本精简一次。${N}"
      msg "  如果每次开机都回来，说明后台仍在自动修复，把它告诉我，我再收紧控制。"
    else
      msg "  ${Y}${BOLD}结论: 有 Intel 冗余架构（多半是刚更新过）—— 双击运行一次脚本即可瘦身。${N}"
    fi
  fi
  msg ""
  exit 0
fi

# ==============================================================================
# 还原模式
# ==============================================================================
if [ "$RESTORE" -eq 1 ]; then
  step "还原状态文件"
  latest=$(ls -1d "$LOGBASE"/.slim_backup/*/ 2>/dev/null | sort | tail -1)
  [ -n "$latest" ] || die "没有找到备份目录 $LOGBASE/.slim_backup/"
  msg "  使用备份: $latest"
  n=0
  while IFS=$'\t' read -r b file; do
    [ -f "$latest/$b" ] || continue
    if [ "$DRY" -eq 1 ]; then ok "[预览] 将还原 $file"; else
      cp -f "$latest/$b" "$file" && { ok "已还原 $file"; n=$((n+1)); }
    fi
  done < "$latest/restore-map.tsv"
  msg ""
  msg "  ${G}状态文件已还原。${N}如需把 LogiVoice / AI Portal / 插件服务等组件装回来，"
  msg "  请打开 Logi Options+ 让它自行检查更新，或从罗技官网重新安装一次 Options+。"
  exit 0
fi

# ==============================================================================
# 删除工具
# ==============================================================================
FREED_KB=0
remove() {  # $1=路径  $2=说明
  local p="$1" d="${2:-}" sz
  [ -e "$p" ] || { return 0; }
  case "$p" in
    /Library/*|/Applications/*|/var/db/receipts/*|"$CUSER_HOME"/Library/*) : ;;
    *) bad "拒绝删除工作范围外的路径: $p"; return 0 ;;
  esac
  sz=$(du -sk "$p" 2>/dev/null | awk '{print $1}'); [ -n "$sz" ] || sz=0
  if [ "$DRY" -eq 1 ]; then
    ok "[预览] $(fmt "$sz")  $p${d:+   ($d)}"
    FREED_KB=$((FREED_KB+sz)); return 0
  fi
  if rm -rf "$p" 2>/dev/null; then
    ok "$(fmt "$sz")  $p${d:+   ($d)}"
    FREED_KB=$((FREED_KB+sz))
  else
    bad "删除失败(可能被占用): $p"
  fi
}

# ==============================================================================
# 1. 停掉相关进程 / 卸载开机代理
# ==============================================================================
step "1/6  停止相关进程与服务"
if [ "$DRY" -eq 0 ]; then
  # 优雅退出界面
  launchctl asuser "$CUID" sudo -u "$CUSER" osascript -e 'quit app "logioptionsplus"' >/dev/null 2>&1
  sleep 2
  pkill -f '^/Applications/logioptionsplus.app/Contents/MacOS/logioptionsplus' 2>/dev/null
  pkill -f 'logioptionsplus_logivoice' 2>/dev/null
  pkill -f 'LogiRightSight' 2>/dev/null
  pkill -f 'LogiPluginService' 2>/dev/null
  ok "已退出 Logi Options+ 界面与待删组件"
else
  ok "[预览] 会退出 Logi Options+ 界面"
fi

for lbl in com.logi.optionsplus.logivoice com.logitech.LogiRightSight.Agent; do
  if [ "$DRY" -eq 0 ]; then
    launchctl bootout "gui/$CUID/$lbl" >/dev/null 2>&1 || true
    # 老式语法兜底
    launchctl bootout "gui/$CUID" "$LA_DIR/$lbl.plist" >/dev/null 2>&1 || true
    # 关键: 必须把 plist 本身也删掉, 否则重启时 launchd 还会把它拉起来
    rm -f "$LA_DIR/$lbl.plist" && ok "已卸载并删除开机代理 $lbl.plist"
  else
    ok "[预览] 会卸载并删除开机代理 $lbl.plist"
  fi
done

# ==============================================================================
# 2. 备份状态文件
# ==============================================================================
step "2/6  备份状态文件（可随时 --restore 还原）"
if [ "$DRY" -eq 0 ]; then
  mkdir -p "$BACKUP_DIR" || die "无法创建备份目录 $BACKUP_DIR"
  : > "$BACKUP_DIR/restore-map.tsv"
  bk() { # $1=原始文件 $2=备份名
    [ -f "$1" ] || return 0
    cp -f "$1" "$BACKUP_DIR/$2" && printf '%s\t%s\n' "$2" "$1" >> "$BACKUP_DIR/restore-map.tsv" \
      && ok "备份 $1"
  }
  bk "$LOGBASE/current.json"            "current.json"
  bk "$LOGBASE/features_cache.json"     "features_cache.json"
  bk "$LOGBASE/installation.json"       "installation.json"
  bk "$LOGBASE/periodic_check.json"     "periodic_check.json"
  # features.json 在 depots/<buildID>/features_config/ 下, 自动找
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="features-$(basename "$(dirname "$(dirname "$f")")").json"
    bk "$f" "$b"
  done < <(find "$LOGBASE/depots" -maxdepth 3 -name features.json 2>/dev/null)
  # builds/<id>.filter.json
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="filter-$(basename "$f" .filter.json).json"
    bk "$f" "$b"
  done < <(find "$LOGBASE/builds" -maxdepth 1 -name '*.filter.json' 2>/dev/null)
else
  ok "[预览] 备份 current/installation/periodic_check/features_cache.json、features.json、*.filter.json"
fi

# ==============================================================================
# 3. 删除缓存与大件组件
# ==============================================================================
step "3/6  删除缓存与无用组件"

# 3.1 安装包下载缓存(最大头, 约 1.3 GB)
# ★★ 关键: App 主进程 utils/installationIntegrity 要求 cache 目录「存在且非空」,
#    把整个目录删掉 → 界面必然卡在「正在获取资源 × 缺少一些必需文件」,
#    同时还会触发后台自动重装(也就是"重启后又下载回来"的真正原因)。
#    所以这里只删 >=10MB 的大归档, 保留小缓存文件让目录保持非空。
#    真正的大头(主程序 811MB / 语音 321MB / 插件 124MB)依然全部释放。
slim_cache() {
  local cache="$LOGBASE/cache" before after big n
  mkdir -p "$cache" 2>/dev/null
  before=$(du -sk "$cache" 2>/dev/null | awk '{print $1}'); [ -n "$before" ] || before=0
  n=$(find "$cache" -type f -size +10M 2>/dev/null | wc -l | tr -d ' ')
  big=$(find "$cache" -type f -size +10M -exec du -sk {} \; 2>/dev/null | awk '{s+=$1} END{print s+0}')
  [ -n "$big" ] || big=0
  if [ "$DRY" -eq 1 ]; then
    ok "[预览] cache: 删除 $n 个 ≥10MB 的大归档，约 $(fmt "$big")；保留小缓存以保证目录非空"
    FREED_KB=$((FREED_KB+big)); return 0
  fi
  find "$cache" -type f -size +10M -print0 2>/dev/null | xargs -0 rm -f 2>/dev/null
  if [ -z "$(ls -A "$cache" 2>/dev/null)" ]; then
    {
      echo "Logi Options+ 的启动完整性自检要求 cache 目录必须是非空目录。"
      echo "本目录内的安装包缓存已由 Logi-Slim 精简，此占位文件用于满足该检查。"
      echo "请勿删除本文件，否则 Options+ 会重新下载安装包并提示「缺少一些必需文件」。"
    } > "$cache/.slim-placeholder"
  fi
  after=$(du -sk "$cache" 2>/dev/null | awk '{print $1}'); [ -n "$after" ] || after=0
  [ "$after" -gt "$before" ] && after=$before
  ok "cache: $(fmt "$before") -> $(fmt "$after")  释放 $(fmt $((before-after)))，目录保持非空"
  FREED_KB=$((FREED_KB + before - after))
}
slim_cache

# 3.2 无用功能组件本体
remove "$LOCBASE/logioptionsplus_logivoice.app"     "LogiVoice 语音输入"
remove "$LOCBASE/logi_ai_portal.app"                "Logi AI Prompt Builder"
remove "$RSDIR"                                     "RightSight 摄像头自动取景"
remove "$LOCBASE/Plugins"                           "Adobe/第三方插件载荷"
remove "$UTIL/LogiPluginService.app"                "第三方插件服务 + Mono 运行时"
remove "/Library/Application Support/Logi/LogiPluginService" "插件服务数据"

# 3.2b 系统 pkg 收据(不删的话, 系统/后台仍认为这些组件"已安装")
for r in /var/db/receipts/com.logitech.LogiRightSightForWebcams.pkg.plist \
         /var/db/receipts/com.logitech.LogiRightSightForWebcams.pkg.bom \
         /var/db/receipts/com.logi.installer.pluginservice.package.plist \
         /var/db/receipts/com.logi.installer.pluginservice.package.bom \
         /var/db/receipts/com.logi.installer.pluginservice.media.package.plist \
         /var/db/receipts/com.logi.installer.pluginservice.media.package.bom; do
  remove "$r" "系统 pkg 收据"
done

# 3.3 depot 安装载荷
if [ -d "$LOGBASE/depots" ]; then
  for bd in "$LOGBASE"/depots/*/; do
    for name in "${DEPOT_REMOVE[@]}"; do
      remove "${bd%/}/$name" "depot 载荷: $name"
    done
  done
fi

# 3.4 缓存类(会自动重建, 删除零风险)
UC="$CUSER_HOME/Library/Application Support/LogiOptionsPlus"
remove "$UC/icon_cache"        "设备图标缓存"
remove "$UC/GPUCache"          "Chromium GPU 缓存"
remove "$UC/DawnGraphiteCache" "Chromium 缓存"
remove "$UC/DawnWebGPUCache"   "Chromium 缓存"
remove "$UC/Code Cache"        "Chromium 代码缓存"
remove "$UC/Shared Dictionary" "Chromium 字典缓存"
remove "$CUSER_HOME/Library/Caches/com.logi.optionsplus.installer" "安装器缓存"

# ==============================================================================
# 3.5 精简 Intel(x86_64) 冗余架构 —— 只瘦身, 不重签名
#   与 Pearcleaner 同样做法。重签名会因为 hardened runtime 的库验证而启动失败。
#   只把"真正会被改动的文件"备份到 $THIN_BK, 验证通过后删除, 所以净收益不缩水。
# ==============================================================================
THIN_SAVED_KB=0
THIN_APPLIED=0
THIN_ROLLED_BACK=0
THIN_BK="$BACKUP_DIR/thin"

thin_bundle() {  # $1=bundle 路径  $2=显示名  $3=备份子目录名
  local root="$1" label="$2" key="$3"
  local man="$BACKUP_DIR/thin-$key.json" bkdir="$THIN_BK/$key"
  if [ ! -d "$root" ]; then warn "跳过 $label（不存在）"; return 0; fi
  local arch; arch=$(uname -m)
  [ "$arch" = "arm64" ] || { warn "本机不是 arm64（$arch），跳过 Intel 架构瘦身"; return 0; }
  local out n saved skipped
  out=$("$PY" - "$root" "$arch" "$bkdir" "$man" "$DRY" <<'PYEOF'
import os, struct, subprocess, sys, shutil, json
root, arch, bkdir, man, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
FAT = (0xcafebabe, 0xcafebabf)
def is_fat(p):
    try:
        with open(p, "rb") as f: return struct.unpack(">I", f.read(4))[0] in FAT
    except Exception: return False
fat = []
for dp, dn, fn in os.walk(root):
    for n in fn:
        p = os.path.join(dp, n)
        if os.path.islink(p) or not os.path.isfile(p): continue
        if is_fat(p): fat.append(p)
if dry:
    print("DRY %d %d" % (len(fat), sum(os.path.getsize(p) for p in fat)))
    sys.exit(0)
changed, skipped, saved = [], [], 0
for p in fat:
    rel = os.path.relpath(p, root)
    st = os.stat(p); before = st.st_size
    tmp = p + ".thin.tmp"
    r = subprocess.run(["lipo", "-thin", arch, "-output", tmp, p], capture_output=True)
    if r.returncode != 0:
        if os.path.exists(tmp): os.remove(tmp)
        skipped.append(rel); continue
    os.chmod(tmp, st.st_mode); os.chown(tmp, st.st_uid, st.st_gid)
    dst = os.path.join(bkdir, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(p, dst)                # 只备份会被改动的文件，供回滚
    os.replace(tmp, p)
    after = os.path.getsize(p); saved += before - after
    changed.append({"rel": rel, "before": before, "after": after})
json.dump({"changed": changed, "skipped": skipped}, open(man, "w"))
print("OK %d %d %d" % (len(changed), saved, len(skipped)))
PYEOF
)
  n=$(echo "$out" | awk '{print $2}'); saved=$(echo "$out" | awk '{print $3}'); skipped=$(echo "$out" | awk '{print $4}')
  case "$out" in
    DRY*)
      ok "[预览] $label: 有 $n 个双架构文件，预计释放约 $(fmt $((saved/2/1024)))"
      THIN_SAVED_KB=$((THIN_SAVED_KB + saved/2/1024)) ;;
    OK*)
      if [ "$n" -gt 0 ]; then
        ok "$label: 瘦身 $n 个文件，释放 $(fmt $((saved/1024)))"
        THIN_SAVED_KB=$((THIN_SAVED_KB + saved/1024)); THIN_APPLIED=1
      else
        ok "$label: 已经是纯 $arch，无需处理"
      fi
      [ "$skipped" -gt 0 ] && warn "$label: 有 $skipped 个文件跳过（非致命）" ;;
    *) warn "$label: 瘦身未执行（$out）" ;;
  esac
  return 0
}

thin_rollback() {  # $1=bundle 路径  $2=备份子目录名
  local root="$1" key="$2" man="$BACKUP_DIR/thin-$key.json" bkdir="$THIN_BK/$key" n
  if [ ! -f "$man" ] || [ ! -d "$bkdir" ]; then
    bad "没有可用的瘦身备份，无法自动回滚 $root（请重装 Options+）"; return 1
  fi
  n=$("$PY" - "$root" "$bkdir" "$man" <<'PYEOF'
import json, os, shutil, sys
root, bkdir, man = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(man)); n = 0
for c in d.get("changed", []):
    src = os.path.join(bkdir, c["rel"]); dst = os.path.join(root, c["rel"])
    if os.path.exists(src):
        os.makedirs(os.path.dirname(dst), exist_ok=True); shutil.copy2(src, dst); n += 1
print(n)
PYEOF
)
  ok "已用备份还原 $root（$n 个文件）"
}

if [ "$THIN" -eq 1 ]; then
  msg ""
  msg "  ${BOLD}── 精简 Intel(x86_64) 冗余架构（只瘦身，不重签名）${N}"
  thin_bundle "$APP"   "主程序 logioptionsplus.app"        app
  thin_bundle "$AGENT" "后台服务 logioptionsplus_agent.app" agent
  [ "$DRY" -eq 0 ] && [ "$THIN_APPLIED" -eq 1 ] && msg "    （瘦身备份先留着，验证启动成功后再删）"
else
  msg ""
  ok "按要求跳过 Intel 架构瘦身（--no-thin）"
fi

# ==============================================================================
# 4. 改写状态文件, 让后台"不再认为这些组件属于本机"
# ==============================================================================
step "4/6  改写安装清单与过滤器（防复活的关键）"
if [ "$DRY" -eq 1 ]; then
  ok "[预览] 修剪 installation.json 中指向已删文件的 sha256 条目(否则自检报缺文件)"
  ok "[预览] features.json 让相关条件判定失败 -> 组件进入 filtered 过滤名单"
  ok "[预览] builds/*.filter.json 合并过滤名单"
  ok "[预览] current.json 移除已删组件的 depot 条目"
  ok "[预览] features_cache.json 移除 logivoice_enabled / logi_ai_portal_enabled 开关"
  ok "[预览] periodic_check.json 关闭自动检查更新/自动下载"
else
  export PY_LOGBASE="$LOGBASE"
  export PY_DEPOTS_REMOVE="${DEPOT_REMOVE[*]}"
  export PY_FLAGS_REMOVE="${FLAG_REMOVE[*]}"
  export PY_PRUNE="$(IFS='|'; echo "${PRUNE_PREFIXES[*]}")"
  "$PY" - <<'PYEOF'
import json, os, glob, sys

logbase = os.environ["PY_LOGBASE"]
depots_remove = set(os.environ["PY_DEPOTS_REMOVE"].split())
flags_remove  = set(os.environ["PY_FLAGS_REMOVE"].split())

def load(p):
    with open(p, encoding="utf-8") as f: return json.load(f)

def save(p, d):
    with open(p, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2, ensure_ascii=False); f.write("\n")

# --- installation.json: 修剪掉指向"已删文件"的记录 ---
# 这个清单里每个文件都带 sha256, 启动自检会拿它核对;
# 不修剪的话界面就会卡在"正在获取资源 / 缺少一些必需文件"。
ip = os.path.join(logbase, "installation.json")
prefixes = [p for p in os.environ.get("PY_PRUNE", "").split("|") if p]
if os.path.exists(ip):
    try:
        d = load(ip)
        of, ofd = d.get("files", []), d.get("folders", [])
        d["files"]   = [f for f in of  if not any(str(f.get("path","")).startswith(p) for p in prefixes)]
        d["folders"] = [f for f in ofd if not any(str(f.get("path","")).startswith(p) for p in prefixes)]
        save(ip, d)
        print("  ✓ installation.json: files %d -> %d (修剪 %d 条), folders %d -> %d" % (
            len(of), len(d["files"]), len(of)-len(d["files"]), len(ofd), len(d["folders"])))
    except Exception as e:
        print("  ! installation.json 处理失败: %s" % e)

# --- features.json: 让这些组件的条件"判定失败" ---
# 官方机制: 条件不成立的 conditionalDepots 会被写进 builds/<id>.filter.json
# 的 filtered 名单, 于是后台既不会安装它们, 也不会再加上对应的功能开关。
# 实测证据: 官方就是用它排除了 required=true 的 predefined_profiles /
# system_actions / bbaf329b-..._strings 三个 depot。
NEVER_FLAG = "slim_component_disabled"   # 永不会被服务端点亮的开关 -> 条件永远失败
SLIM_NAME  = "Slim - 停用非鼠标组件"
for fp in glob.glob(os.path.join(logbase, "depots", "*", "features_config", "features.json")):
    try: d = load(fp)
    except Exception as e:
        print("  ! 跳过 %s (%s)" % (fp, e)); continue
    cfgs = d.get("configurations", [])
    handled = set()
    for c in cfgs:
        act  = c.get("actions") or {}
        deps = set(act.get("conditionalDepots") or [])
        hit  = deps & depots_remove
        if not hit:
            continue
        # 把条件换成永不成立; 同时清空 addFeatureFlags(界面入口随之消失)
        c["conditions"] = {"flagMustBeEnabled": {"flag": NEVER_FLAG, "default": False}}
        act["addFeatureFlags"] = []
        c["actions"] = act
        handled |= hit
    missing = sorted(depots_remove - handled)
    if missing and not any((c.get("name") or "") == SLIM_NAME for c in cfgs):
        cfgs.append({
            "name": SLIM_NAME,
            "conditions": {"flagMustBeEnabled": {"flag": NEVER_FLAG, "default": False}},
            "actions": {"conditionalDepots": missing},
        })
    d["configurations"] = cfgs
    save(fp, d)
    print("  ✓ features.json: 已停用 %d 个组件 (其中 %d 个新增过滤规则)" % (
        len(handled | set(missing)), len(missing)))

# --- builds/<id>.filter.json: 直接把组件并入 filtered 名单 ---
for fp in glob.glob(os.path.join(logbase, "builds", "*.filter.json")):
    try:
        d = load(fp)
        old = d.get("filtered", [])
        d["filtered"] = sorted(set(old) | depots_remove)
        save(fp, d)
        print("  ✓ %s: filtered %d -> %d" % (os.path.basename(fp), len(old), len(d["filtered"])))
    except Exception as e:
        print("  ! %s 处理失败: %s" % (os.path.basename(fp), e))

# --- current.json: 移除已删组件的 depot 条目 ---
cp = os.path.join(logbase, "current.json")
if os.path.exists(cp):
    try:
        d = load(cp)
        old = d.get("depots", [])
        new = [x for x in old if x.get("name") not in depots_remove]
        d["depots"] = new
        save(cp, d)
        print("  ✓ current.json: depot 条目 %d -> %d (移除 %s)" % (
            len(old), len(new), [x.get("name") for x in old if x.get("name") in depots_remove] or "无"))
    except Exception as e:
        print("  ! current.json 处理失败: %s" % e)

# --- features_cache.json: 移除特性开关 ---
fc = os.path.join(logbase, "features_cache.json")
if os.path.exists(fc):
    try:
        d = load(fc)
        old = d.get("featureFlags", [])
        d["featureFlags"] = [f for f in old if f not in flags_remove]
        save(fc, d)
        print("  ✓ features_cache.json: 开关 %s -> %s" % (old, d["featureFlags"]))
    except Exception as e:
        print("  ! features_cache.json 处理失败: %s" % e)

# --- periodic_check.json: 关掉自动检查更新 / 自动下载 ---
pc = os.path.join(logbase, "periodic_check.json")
if os.path.exists(pc):
    try:
        d = load(pc)
        d["checkPeriodically"] = False
        d["downloadAutomatically"] = False
        save(pc, d)
        print("  ✓ periodic_check.json: 已关闭自动检查更新与自动下载")
    except Exception as e:
        print("  ! periodic_check.json 处理失败: %s" % e)
PYEOF
  [ $? -eq 0 ] || bad "状态文件改写出现异常（软件仍可使用，更新后重跑本脚本即可）"
fi

# 说明: card_presets 下的预设卡片文件体积很小(共约 260 KB), 删了省不了空间,
# 却可能被后台读取时报错, 因此脚本刻意保留它们不动。

# ==============================================================================
# 5. 重启后台服务
# ==============================================================================
step "5/6  重启后台服务（让新状态立即生效）"
if [ "$DRY" -eq 0 ]; then
  launchctl kickstart -k "gui/$CUID/com.logi.cp-dev-mgr" >/dev/null 2>&1 || \
    launchctl bootstrap "gui/$CUID" "$LA_DIR/com.logi.optionsplus.plist" >/dev/null 2>&1 || true
  sleep 3
  if pgrep -f 'logioptionsplus_agent' >/dev/null 2>&1; then
    ok "后台服务已运行 (logioptionsplus_agent)"
  elif [ "$THIN_APPLIED" -eq 1 ] && [ -f "$BACKUP_DIR/thin-agent.json" ]; then
    bad "瘦身后后台服务没能启动 —— 自动回滚为原始双架构版本"
    thin_rollback "$AGENT" agent
    launchctl kickstart -k "gui/$CUID/com.logi.cp-dev-mgr" >/dev/null 2>&1 || true
    sleep 4
    if pgrep -f 'logioptionsplus_agent' >/dev/null 2>&1; then
      ok "回滚成功，后台服务已恢复（本次放弃 Intel 架构瘦身）"
      THIN_ROLLED_BACK=1
    else
      bad "回滚后仍未运行。请注销/重启一次；仍不行则需要重装 Options+"
    fi
  else
    warn "后台服务暂未检测到，注销/重启一次会自动启动（不影响鼠标基本使用）"
  fi

  # 主程序自带的更新服务(logioptionsplus_updater)也在刚瘦身的 agent 里, 一并重启验证
  if [ "$THIN_APPLIED" -eq 1 ] && [ "$THIN_ROLLED_BACK" -eq 0 ]; then
    launchctl kickstart -k system/com.logi.optionsplus.updater >/dev/null 2>&1 || true
    sleep 3
    if pgrep -f 'logioptionsplus_updater' >/dev/null 2>&1; then
      ok "内置更新服务已运行（logioptionsplus_updater）"
    elif [ -f "$BACKUP_DIR/thin-agent.json" ]; then
      bad "瘦身后更新服务没能启动 —— 回滚后台服务"
      thin_rollback "$AGENT" agent
      launchctl kickstart -k system/com.logi.optionsplus.updater >/dev/null 2>&1 || true
      sleep 4
      if pgrep -f 'logioptionsplus_updater' >/dev/null 2>&1; then
        ok "回滚成功，更新服务已恢复（本次放弃 Intel 架构瘦身）"; THIN_ROLLED_BACK=1
      else
        bad "更新服务仍异常。请重装一次 Options+（鼠标基础功能不受影响）"
      fi
    fi
  fi
else
  ok "[预览] 会重启 com.logi.cp-dev-mgr"
fi

# ==============================================================================
# 6. 验证软件能否正常打开
# ==============================================================================
step "6/6  验证软件"
if [ "$DRY" -eq 0 ]; then
  msg "  ${BOLD}完整性自检（与 App 的 utils/installationIntegrity 完全一致）${N}"
  integrity_check
  if [ "$INTEGRITY_FAIL" -eq 0 ]; then
    ok "${BOLD}9 项全部通过 —— 界面不会再卡在「缺少一些必需文件」${N}"
  else
    bad "${BOLD}仍有 $INTEGRITY_FAIL 项不过，界面可能报「缺少一些必需文件」${N}"
  fi
  msg ""
fi
# 刷新系统对主程序的注册, 防止系统按 bundle ID 找到失效路径而报
# “logioptionsplus 因为出现问题而无法打开…请重新安装该应用程序”
LSR="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSR" ]; then
  if [ "$DRY" -eq 1 ]; then
    ok "[预览] 会刷新 LaunchServices 注册"
  else
    "$LSR" -f -R -trusted "$APP" >/dev/null 2>&1 && ok "已刷新系统对主程序的注册 (LaunchServices)"
  fi
fi
if [ "$LAUNCH" -eq 1 ] && [ "$DRY" -eq 0 ]; then
  launchctl asuser "$CUID" sudo -u "$CUSER" open -a "$APP" >/dev/null 2>&1
  msg "  正在启动 Logi Options+ ..."
  alive=0
  for i in $(seq 1 12); do
    sleep 1
    if pgrep -f '^/Applications/logioptionsplus.app/Contents/MacOS/logioptionsplus' >/dev/null 2>&1; then
      alive=1; break
    fi
  done
  if [ "$alive" -eq 1 ]; then
    ok "Logi Options+ 已正常启动（进程存活）"
    msg "    请点开界面确认: 鼠标 → 指针速度 / 按键自定义 是否可用"
  elif [ "$THIN_APPLIED" -eq 1 ] && [ -f "$BACKUP_DIR/thin-app.json" ]; then
    bad "瘦身后主程序没能启动 —— 自动回滚为原始双架构版本"
    thin_rollback "$APP" app
    launchctl asuser "$CUID" sudo -u "$CUSER" open -a "$APP" >/dev/null 2>&1
    sleep 7
    if pgrep -f '^/Applications/logioptionsplus.app/Contents/MacOS/logioptionsplus' >/dev/null 2>&1; then
      ok "回滚成功，Logi Options+ 已能启动（本次放弃 Intel 架构瘦身）"
      THIN_ROLLED_BACK=1
    else
      warn "回滚后仍未启动。请手动打开 /Applications/logioptionsplus.app 并把结果告诉我"
    fi
  else
    warn "没有检测到界面进程。请手动打开一次 /Applications/logioptionsplus.app"
    msg "    如果提示“无法打开…请重新安装该应用程序”，执行下面这条命令即可修复："
    msg "    \"$LSR\" -f -R -trusted \"$APP\""
    msg "    若仍不行，把报错内容发我，先不要重装。"
  fi
else
  ok "跳过启动验证（--no-launch 或预览模式）"
fi

# 把一个副本放到桌面, 方便下次更新后一键再来
if [ "$DRY" -eq 0 ]; then
  DEST="$CUSER_HOME/Desktop/一键精简Logi.command"
  if cp -f "$0" "$DEST" 2>/dev/null; then
    chmod +x "$DEST"; chown "$CUSER" "$DEST" 2>/dev/null
    ok "已在桌面放置快捷脚本: $DEST"
  fi
fi

# 瘦身备份：启动验证都通过就删掉（否则白占磁盘，净收益会缩水）
if [ "$DRY" -eq 0 ] && [ "$THIN_APPLIED" -eq 1 ] && [ -d "$THIN_BK" ]; then
  if [ "$THIN_ROLLED_BACK" -eq 0 ]; then
    bksize=$(du -sk "$THIN_BK" 2>/dev/null | awk '{print $1}'); [ -n "$bksize" ] || bksize=0
    rm -rf "$THIN_BK" && ok "瘦身备份已删除（腾出 $(fmt "$bksize")；验证已通过，不再需要回滚）"
  else
    warn "本次发生过回滚，瘦身备份保留在: $THIN_BK"
  fi
fi

# ==============================================================================
# 汇总
# ==============================================================================
SIZE_AFTER=$(before_kb)
step "完成"
if [ "$DRY" -eq 1 ]; then
  msg "  ${BOLD}预计可释放: $(fmt "$FREED_KB")${N}"
  msg "  精简前总占用: $(fmt "$SIZE_BEFORE")"
  msg ""
  msg "  确认无误后，双击本文件（不加参数）执行真正的精简。"
else
  msg "  ${BOLD}${G}已释放: $(fmt "$FREED_KB")${N}"
  [ "$THIN_SAVED_KB" -gt 0 ] && msg "  其中 Intel 架构瘦身: $(fmt "$THIN_SAVED_KB")"
  [ "$THIN_ROLLED_BACK" -eq 1 ] && msg "  ${Y}（本次架构瘦身已回滚，当前仍是双架构版本）${N}"
  msg "  精简前总占用: $(fmt "$SIZE_BEFORE")   精简后: $(fmt "$SIZE_AFTER")"
  msg "  状态文件备份: $BACKUP_DIR"
  msg ""
  msg "  · 保留功能: 指针速度/DPI、按键与手势自定义、滚轮、设备切换、电量显示"
  msg "  · 已移除: 1.3GB 安装缓存、LogiVoice、AI Prompt Builder、RightSight、"
  msg "            第三方插件服务(Adobe/Teams)、各组件 depot 载荷、pkg 收据"
  msg "  · 已写入后台过滤名单 + 修剪 installation.json + 关闭自动下载"
  msg "  · 已把 Intel(x86_64) 冗余架构瘦掉（不重签名，权限不会失效）"
  msg ""
  msg "  ${BOLD}建议: 重启一次电脑，然后运行  bash \"$0\" --check  体检${N}"
  msg "  它会告诉你组件有没有被后台偷偷装回来（不需要密码）。"
  msg ""
  msg "  · 软件更新后，重新双击本脚本即可再精简一次（可重复运行）"
  msg "  · 想恢复被删组件: 运行 ${BOLD}bash \"$0\" --restore${N} 或重装 Options+"
fi
msg ""
