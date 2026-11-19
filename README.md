# 愚者途径 LOTM Pathways

《诡秘之主》× 潜渊症。把序列体系缝进木卫二的深海：喝魔药踏上途径，用能力推进"扮演消化"，消化不足就强行晋升会失控。

本仓库根目录就是一个完整的 Barotrauma 内容包（content package），可直接放进 `LocalMods` 使用。

---

## 安装

1. 把本仓库整个目录放到 `Barotrauma/LocalMods/LOTM_Pathways/`
2. 安装 **LuaCsForBarotrauma**（创意工坊）**并打客户端补丁**
   - 补丁：https://github.com/evilfactory/LuaCsForBarotrauma/releases/tag/latest
   - 下载 `luacsforbarotrauma_patch_windows_client.zip`，解压覆盖到游戏根目录
   - **跳过这步，物品能用但所有机制（晋升/失控/掉特性/占卜/HUD）都不会生效**
   - Steam 每次更新游戏都会覆盖回原版 DLL，更新后需重打补丁
3. 游戏内模组列表启用，顺序：LuaCs 在上，本 mod 在下

---

## 已实现

- **序列状态**：序列 9 占卜家 / 8 小丑 / 7 魔术师，常驻 buff，提升生命上限、移速、近战、减伤、憋气
- **三条资源**：灵性（自然回复）、疯狂（不衰减、70% 起侵蚀理智）、扮演消化度
- **灵视**：主动开关，持续消耗灵性，枯竭自动关闭并附加"灵视反噬"
- **完整原著配方**：17 种材料；医疗台只有 5 个输入格，所以拆成"基液 → 魔药"两步
- **双晋升路线**：原著材料路线 / 非凡特性替代路线
- **风险判定**：未消化强行晋升按 `(100-消化)×0.6` 累积疯狂，满 100 失控死亡并原地生成怪物
- **死亡掉落非凡特性**：尸体旁生成对应特性，可被队友回收
- **占卜**：关键词匹配 + 真实游戏状态（附近活物、重伤船员），准确率随消化度提升
- **HUD**（实验性）：生命/灵性/疯狂/消化四条文本进度条 + 灵视、占卜按钮

---

## 聊天指令

> 这些是**聊天指令**（按 T 打开聊天框），不是 F3 调试控制台命令。

### 按键（可在 LuaCs 模组设置里修改）

| 默认键 | 功能 |
|---|---|
| `F` | 火焰跳跃（序列 7） |
| `G` | 幻术（序列 7） |
| `V` | 灵视开关 |

> 内容包名称是 `LOTM_Pathways`（ASCII），因为 LuaCs 的按键设置文本键使用 `<包名>.<设置名>.DisplayName` 格式，中文或空格会导致设置项无法翻译。

| 指令 | 说明 |
|---|---|
| `!状态` / `!status` | 查看生命、灵性、疯狂、消化、序列 |
| `!灵视` / `!vision` | 开关灵视 |
| `!占卜 问题` / `!divine 问题` | 占卜，需要随身携带占卜水晶，消耗 30 灵性 |
| `!界面` / `!hud` | 显示/隐藏 HUD |
| `!lotm` | 自检，确认脚本在线 |

---

## 文件结构

```
.
├─ filelist.xml          内容包声明
├─ ModConfig.xml         LuaCs 脚本声明（IsAutorun）
├─ Afflictions.xml       序列 / 灵性 / 疯狂 / 消化 / 灵视 状态
├─ Items/
│  ├─ Materials.xml      17 种原著材料
│  ├─ Potions.xml        基液 + 魔药 + 非凡特性 + 双路线配方
│  └─ Tools.xml          占卜水晶、纸人
├─ Texts/                中英文文本
├─ Lua/lotm.lua          逻辑层（ASCII only，中文走 Texts）
└─ 使用说明.txt          安装、指令、测试清单
```

---

## 已知限制

- HUD 为实验性 GUI 挂载，显示异常时用聊天指令
- 多人模式未做联网同步（单机优先）
- 占卜是关键词匹配，不是自由问答
- 纸人替死、火焰跳跃等主动技能尚未实装

---

## 开发提示

- 改完 `Lua/lotm.lua`：F3 控制台输入 `cl_reloadluacs` 热重载，不用重启游戏
- 改完 XML：`reloadcontentfile <路径>`，或重启
- 调试：`enablecheats` 后可用 `spawnitem lotm_potion_seq9`、`giveaffliction lotm_madness 90`
