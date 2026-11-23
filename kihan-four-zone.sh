#!/system/bin/sh
# ============================================================
#  火影忍者 (com.tencent.KiHan) 1.80.80.8
#  「四区」四入口登录补丁  —— 已实测生效
#  author: miskey0319  |  Telegram: @miskey0319
#  (逆向分析: 小满)
# ------------------------------------------------------------
#  目标: libil2cpp.so  KH.TxGameAssistantManager::CanLoginByAndroidAndIOS
#        模块相对偏移 0x8FD18BC   (vaddr == file offset)
#        改写为      0x52800020  mov w0,#1
#                    0xD65F03C0  ret
#
#  为什么是它: 登录窗口 KH.ChooseLoginTypeWin::Start 里直接调用它，
#  返回 true 时才把 _btnTXIOSQQ / _btnTXIOSWeixin 两个 iOS 按钮
#  一起显示出来 => 登录页出现
#        与IOS好友玩(微信) / 与安卓好友玩(微信)
#        与IOS好友玩(QQ)   / 与安卓好友玩(QQ)
#
#  实测记录(1.80.80.8):
#    · CanLoginByAndroidAndIOS 入度正常，登录 Start 直接调用 -> 有效
#    · KH.DolphinSpeedManager::get_IsEnableTestServer(0x84EF510) 入度 0
#      (354 万条 BL 全扫，没有任何指令调用它) -> 打它没有任何效果
#    · KH.KHGlobalExt::IsEmulator / Pandora::IsEmulator /
#      CSharpInterface::IsEmulator / Lua 层 IsEmulator_s 全打 true，
#      登录页依然只有两个入口 -> 模拟器判定不是这条链的开关
# ============================================================

PKG="com.tencent.KiHan"
SO="libil2cpp.so"
TMP="/data/local/tmp/.kihan_patch.bin"

# 偏移:补丁字节   (mov w0,#1 ; ret = 20008052c0035fd6)
PATCHES="
8FD18BC:20008052c0035fd6
"

# ---- 64 位十六进制加法(安卓 mksh 算术只有 32 位, 直接 $((16#...)) 会截断) ----
addhex() {
  a=$1; b=$2
  while [ ${#a} -lt ${#b} ]; do a="0$a"; done
  while [ ${#b} -lt ${#a} ]; do b="0$b"; done
  res=""; carry=0; i=${#a}
  while [ "$i" -gt 0 ]; do
    i=$((i-1))
    da=$(printf %d "0x${a:$i:1}"); db=$(printf %d "0x${b:$i:1}")
    s=$((da+db+carry))
    if [ "$s" -ge 16 ]; then s=$((s-16)); carry=1; else carry=0; fi
    res="$(printf %x "$s")$res"
  done
  [ "$carry" -eq 1 ] && res="1$res"
  echo "$res"
}

rd() { dd if=/proc/$PID/mem bs=1 skip=0x$1 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n'; }

# ---------- 1. 拉起游戏 ----------
if [ -z "$(pidof $PKG)" ]; then
  echo "[*] 启动 $PKG ..."
  monkey -p "$PKG" -c android.intent.category.LAUNCHER --pct-syskeys 0 1 >/dev/null 2>&1
fi

# ---------- 2. 等真正加载了 libil2cpp 的进程 ----------
PID=""
i=0
while [ "$i" -lt 120 ]; do
  for p in $(pidof $PKG); do
    if [ -r /proc/$p/maps ] && grep -q "$SO" /proc/$p/maps 2>/dev/null; then PID=$p; break; fi
  done
  [ -n "$PID" ] && break
  i=$((i+1)); sleep 0.5
done
if [ -z "$PID" ]; then echo "[!] 等不到 $PKG 加载 $SO"; exit 1; fi

# ---------- 3. 基址 = maps 里 offset=0 那一段的起点 ----------
BASE=""
while read -r range perms off rest; do
  if [ "$off" = "00000000" ]; then BASE=${range%%-*}; break; fi
done <<EOF
$(grep "$SO" /proc/$PID/maps)
EOF
if [ -z "$BASE" ]; then echo "[!] maps 里找不到 $SO 的 offset=0 段"; exit 1; fi
echo "PID=$PID  BASE=0x$BASE"

# ---------- 4. 逐个打补丁 ----------
for item in $PATCHES; do
  OFF=${item%%:*}
  VAL=${item#*:}
  ADDR=$(addhex "$BASE" "$OFF")
  echo "$VAL" | xxd -r -p > "$TMP"
  if [ "$(od -An -tx1 "$TMP" | tr -d ' \n')" != "$VAL" ]; then
    echo "[!] 补丁字节生成失败: $VAL"; continue
  fi
  echo "[*] 0x$OFF 原字节 = $(rd $ADDR)"
  k=0; ok=0
  while [ "$k" -lt 10 ]; do
    dd if="$TMP" of=/proc/$PID/mem bs=1 seek=0x$ADDR conv=notrunc 2>/dev/null
    sleep 0.2
    GOT=$(rd $ADDR)
    if [ "$GOT" = "$VAL" ]; then ok=1; break; fi
    k=$((k+1))
  done
  if [ "$ok" = "1" ]; then
    echo "[+] 已生效: 0x$OFF = $VAL"
  else
    echo "[!] 0x$OFF 写入失败, 当前=$(rd $ADDR)"
  fi
done
rm -f "$TMP"
echo "done PID=$PID"
