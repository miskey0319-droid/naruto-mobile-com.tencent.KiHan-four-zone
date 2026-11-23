# 排查报告：为什么旧的「火影四区.sh」失效，以及正确目标怎么找

> 对象：`com.tencent.KiHan` 1.80.80.8（versionCode 1080080008）
> 环境：Android 16 / KernelSU，arm64-v8a
> 结论：四入口开关是 `KH.TxGameAssistantManager::CanLoginByAndroidAndIOS`（libil2cpp.so + 0x8FD18BC）

---

## 1. 旧脚本失效的直接原因

旧脚本对 `libil2cpp.so` 的三处偏移写 `mov w0,#1; ret`。这三处在 1.80.80.8 里**恰好都是函数入口**
（所以回读字节必然「匹配」），但指向的是完全无关的函数：

| 旧偏移 | 1.80.80.8 里实际是什么 |
|---|---|
| `0x89F5340` | `UnityHFSM.Timer::op_LessThan` |
| `0x806101C` | `KH.CrashTestCase::TestReportError1` |
| `0x5386CE0` | `com.tencent.pandora.NGUIRadar::get_material` |

脚本注释里写的「KH层 / Pandora层 / Lua层 IsEmulator」全部对不上。真正的 IsEmulator 方法地址是：

- `KH.KHGlobalExt::IsEmulator` = `0x8412CA8`
- `com.tencent.pandora.Pandora::IsEmulator` = `0xA083C84`
- `com.tencent.pandora.CSharpInterface::IsEmulator` = `0xA083C6C`
- `Lua_com_tencent_pandora_CSharpInterface::IsEmulator_s` = `0x56C14A0`

**所以「回读字节一致」不能作为「补丁成功」的证据** —— 它只证明写进去了。

## 2. 从 APK 重建「方法名 → 地址」全表

### 2.1 取文件
```
/data/app/.../lib/arm64/libil2cpp.so            214,743,000 B
assets/bin/Data/Managed/Metadata/global-metadata.dat   44,576,004 B
```
注意安装后的目录名是 `lib/arm64/`，不是 `arm64-v8a/`。

### 2.2 解 metadata
按 0x10000 分块：块 0 的 `[0,0x5000)` 整体 XOR 0x66；之后每块 `[k*0x10000+0x1000, +0x5000)` XOR 0x66。
（前 8 字节 sanity/version 是另一套，不影响解析。）

### 2.3 解析 v29 头
31 组 `(offset, count)`，count 是**字节数**，header 长 0x100。
关键表：`methods` 10876224 B（32 B/条 = 339,882 个）、`typeDefinitions` 4116024 B（88 B/条 = 46,773 个）、`images` 4400 B（40 B/条 = 110 个）。

TypeDefinition 布局（实测，靠「8 个 u16 的求和 == 全表总数」验证）：

```
+0 name +4 ns +8 byval +12 byref +16 parent +20 ? +24 ? +28 ?
+32 fieldStart  +36 methodStart  +40 eventStart  +44 propertyStart
+48 nestedTypesStart +52 interfacesStart +56 vtableStart +60 interfaceOffsetsStart
+64 u16 method_count  +66 property_count  +68 field_count  +70 event_count
+72 nested_type_count +74 vtable_count  +76 interfaces_count +78 interface_offsets_count
```
自检：`Σmethod_count = 339882`、`Σfield_count = 352482`、`Σproperty_count = 40127`。

MethodDefinition（32 B）：`+0 name +4 declaringType +8 returnType +12 paramStart +16 genericContainerIndex +20 token ...`

### 2.4 找 CodeGenModule（.so 侧）
1. 全文件搜 `"Assembly-CSharp.dll\0"` → 唯一一处，vaddr `0x15319A0`；
2. 解析 `.rela.dyn`（off `0x1A5C8`, size `0x14EA7A8`，913,831 条），找 `R_AARCH64_RELATIVE(1027)` 且 `addend == 0x15319A0` 的槽 → `0xC54EC18`，即 codeGenModule；
3. 结构：`+0 moduleName, +8 u32 methodPointerCount, +16 methodPointers[]`：
   `methodPointerCount = 146,786`，`methodPointers = 0xCB8FDC0`；
4. 数组每 8 字节也是一个 `R_AARCH64_RELATIVE` 槽，addend 就是函数 vaddr。

### 2.5 索引规则（关键）
**methodPointers 的下标 = 方法在该 image 内的定义序号，泛型不跳过。**

证据：
- image0（Assembly-CSharp）所有 type 的 `method_count` 求和 = **146,786**，正好等于 `methodPointerCount`；
- 而 image0 内部存在泛型方法（前 84240 个里就有 403 个），如果按「跳过泛型」折算，数量不可能相等；
- image1（khengine.runtime.dll）第一个非空 type 的 `methodStart` = 146,786，与 image0 的结束严丝合缝。

所以 `KH.DolphinSpeedManager::get_IsEnableTestServer`（全局方法 84240）→ `methodPointers[84240]` = `0x84EF510`。

## 3. 三个候选方案的真机验证

| 方案 | 偏移 | 结果 |
|---|---|---|
| 测试服开关 `get_IsEnableTestServer` | 0x84EF510 | ❌ 登录页仍两个入口 |
| 四个 `IsEmulator`（KH/Pandora/CSharpInterface/Lua） | 0x8412CA8 / 0xA083C84 / 0xA083C6C / 0x56C14A0 | ❌ 登录页仍两个入口 |
| `CanLoginByAndroidAndIOS` | **0x8FD18BC** | ✅ 出现四个入口 |

### 3.1 入度统计（决定性）
全量扫描代码段 `0x409B090..0xC178EE0` 里的 `BL`（`(w & 0xFC000000) == 0x94000000`）：

- 共 3,548,763 条 BL，94,546 个不同目标，入度中位数 1；
- `get_IsEnableTestServer` = **入度 0**（没有任何代码调用它，官方这条判定已经死了）；
- `KH.KHGlobalExt::IsEmulator` = 入度 6，但调用它的是 `KHGameFlow::Start` / `GetPlatType` / 录屏 / 上报，**不在登录按钮链上**。

### 3.2 突破口：运行时 dump
`KH.ChooseLoginTypeWin::Start`（`0x4A8D514`）在文件里是**加密**的（首字节 `59 e0 f0 12`，整段不是合法 AArch64）。
从运行中的进程 dump 出来就是明文：

```
dd if=/proc/16448/mem of=/data/local/tmp/start.bin bs=1 skip=$((BASE+0x4A8D514)) count=0xBEC
```
```
e80f19fc fd7b01a9 fc6f02a9 fa6703a9 ...   ← 合法 stp 序言
```

把函数体里的 BL 目标换算回文件偏移再反查方法名，调用列表里就有：

```
KH.TxGameAssistantManager::CanLoginByAndroidAndIOS   ← 就是这个
KH.ChooseLoginTypeWin::FocusOnSelectedServer / ChangeNetType / closeWeChatLogin
KH.KHPluginManager::SendMessage, BtnServer::Init/Selected/UnSelect ...
```

## 4. 复现 / 换版本后重新定位

1. 从 APK 取 `libil2cpp.so` 和 `global-metadata.dat`（`unzip -p`）；
2. 解密 metadata，按第 2.3 节解析，搜方法名 → 得到全局方法号 `i`；
3. 找到该方法所属 image，算出 `i - image 首个方法号` 即数组下标；
4. 在 `.so` 里定位该方法所属模块的 codeGenModule，读 `methodPointers[下标]` = 新偏移；
5. 先查入度：入度 0 就说明这条路死了，别浪费时间；
6. 加密块里的函数用 `/proc/<pid>/mem` dump 出来再反汇编。

## 5. 工具链细节

- `re.finditer(rb"[\x94-\x97]", chunk)` 先筛 BL 的最高字节，比逐字解码快两个数量级；
- 安卓 mksh 算术 32 位，64 位十六进制加法必须自己实现；
- toybox `dd` 认 `skip=0x...`；`xxd` / `bc` 都在 `/system/bin`；
- `/proc/<pid>/mem` 写 `r-xp` 页会触发 COW，不需要 mprotect，也不需要额外权限（root）。

## 6. 作者

**miskey0319** · Telegram [@miskey0319](https://t.me/miskey0319)
逆向分析由 小满 协助。
