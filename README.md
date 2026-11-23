# 火影忍者 Naruto Mobile · com.tencent.KiHan · 1.80.80.8 · 四区四入口登录补丁

让《火影忍者》手游（`com.tencent.KiHan` 1.80.80.8，Unity 2021.3.16f1 / IL2CPP / arm64-v8a）
的登录页同时显示**四个**登录入口：

| | 微信 | QQ |
|---|---|---|
| iOS | 与IOS好友玩 | 与IOS好友玩 |
| 安卓 | 与安卓好友玩 | 与安卓好友玩 |

不需要改 APK、不需要重签名，运行时往 `/proc/<pid>/mem` 里写两条指令即可。

## 原理

登录窗口 `KH.ChooseLoginTypeWin::Start` 在构建按钮时调用
`KH.TxGameAssistantManager::CanLoginByAndroidAndIOS`：

- 返回 `false`（正常手机）→ 只显示 `_btnQQ` / `_btnWeixin` 两个按钮
- 返回 `true` → 连 `_btnTXIOSQQ` / `_btnTXIOSWeixin` 一起显示，即四个入口

把该函数入口改成 `mov w0,#1; ret`（恒返回 true）就得到四入口。

```
; libil2cpp.so + 0x8FD18BC
2079:  0x52800020   mov w0, #1
207c:  0xD65F03C0   ret
```

## 用法

```sh
adb push kihan-four-zone.sh /data/local/tmp/
adb shell su -c "sh /data/local/tmp/kihan-four-zone.sh"
```

或用 MT 管理器 / Termux 以 root 直接执行。脚本会：

1. 没在跑就先拉起游戏；
2. 从 `pidof` 里挑出真正映射了 `libil2cpp.so` 的那个进程；
3. 用 `maps` 里 `offset=00000000` 那一段的起点当模块基址；
4. 写 `mov w0,#1; ret`，回读校验，失败重试 10 次。

输出示例：

```
[*] 启动 com.tencent.KiHan ...
PID=16448  BASE=0x6e21088000
[*] 0x8FD18BC 原字节 = fe4fbfa973e701b0
[+] 已生效: 0x8FD18BC = 20008052c0035fd6
done PID=16448
```

## 关键偏移（1.80.80.8）

| 目标 | 偏移 | 结论 |
|---|---|---|
| `KH.TxGameAssistantManager::CanLoginByAndroidAndIOS` | **0x8FD18BC** | ✅ 打这里出四入口 |
| `KH.DolphinSpeedManager::get_IsEnableTestServer` | 0x84EF510 | ❌ BL 入度 0（没人调用） |
| `KH.KHGlobalExt::IsEmulator` | 0x8412CA8 | ❌ 全打 true 仍只有两个入口 |
| `com.tencent.pandora.Pandora::IsEmulator` | 0xA083C84 | ❌ 同上 |
| `com.tencent.pandora.CSharpInterface::IsEmulator` | 0xA083C6C | ❌ 同上 |
| `Lua_com_tencent_pandora_CSharpInterface::IsEmulator_s` | 0x56C14A0 | ❌ 同上 |

> 偏移是 **libil2cpp.so 的 vaddr，等于文件偏移**（该 so 的代码段 vaddr==offset）。
> 游戏每个版本都会重排，换版本必须重新定位，方法见 [docs/ANALYSIS.md](docs/ANALYSIS.md)。

## 已知坑

- **安卓 mksh 的算术只有 32 位**：`$((16#6e21088000))` 会截断成 `0x1088000`，必须自己做逐位十六进制加法。
- 游戏进程早期只加载 `libtersafe.so`（TenProtect），此时 `libil2cpp.so` 还没映射，`maps` 里看不到它，属正常。
- 安装后原生库目录是 `lib/arm64/`（不是 `arm64-v8a/`）。
- `libil2cpp.so` 里有一批 16KB 代码块在 APK 中是**加密**的，由加固运行时解密；静态反汇编看不到内容，需要从 `/proc/<pid>/mem` dump。

## 免责声明

个人逆向学习与自用工具，只修改本地进程内存、不改动客户端文件、不涉及任何网络协议或账号数据。
使用风险自负；请遵守游戏服务条款与当地法律，不要用于商业用途或传播破解版本。

## 作者

**miskey0319** · Telegram [@miskey0319](https://t.me/miskey0319)

由 小满 协助完成逆向分析。
