# Rolltop glossary (English → Simplified Chinese)

One English term per thing, one Chinese term per English term. English follows US spelling and
Apple's names; Chinese follows Apple's zh-Hans names for system concepts. Memory files in
`tm/` use these; `l10n.py` reports keys whose translation is missing or whose placeholders differ.

## Rolltop's own concepts

| English | 简体中文 | Note |
|---|---|---|
| Rolltop | Rolltop | Never translated. |
| Rolltop’s icon (the main status item) | Rolltop 图标 | “its icon” in captions means the same icon. |
| Rolltop’s menu | Rolltop 菜单 | The menu of Rolltop’s icon (right-click or Control-click). |
| menu bar item, item | 菜单栏项, 项 | “Hidden items” → 隐藏项. Counted: “%lld 项”. |
| section | 分区 | The three sections below. In sentences quote the name: 移到“隐藏”. |
| Shown | 显示 | Section name. Lower-case “shown” in summaries → 显示. |
| Hidden | 隐藏 | Section name. |
| Always Hidden / always-hidden items | 始终隐藏 / 始终隐藏的项 | Hyphenated only before a noun in English. |
| new items, section for new items | 新项, 新项所在分区 | Apps seen for the first time. |
| Rolltop Bar | Rolltop 栏 | The glass panel below the menu bar (PLAN: 副栏). |
| Shelf, the shelf | 搁架 | The notch panel. |
| file shelf | 文件暂存 | The shelf’s file area (PLAN wording). |
| clipboard history, clip | 剪贴板历史, 剪贴记录 | “%lld clips” → “%lld 条剪贴记录”. |
| Up next | 即将开始 | The shelf’s calendar area. Quoted (“即将开始”) in sentences. Calendar.app has no “Up Next” string to follow (checked); unsure. |
| Search (the palette) | 搜索 | Pane title and panel; “command palette” only as a search keyword (命令面板). |
| profile | 预设 | PLAN wording. Appearance “presets” are 内置样式 to keep them apart. |
| automation | 自动化 | The objects in the Automations pane; English no longer says “rule” for them. |
| condition, action | 条件, 操作 | 操作 as in Shortcuts (添加操作). |
| custom items: spacer, group, widget | 自定义项: 间隔符, 分组, 小组件 | |
| template | 模板 | Starting points for automations and custom items. |
| preset (appearance style) | 内置样式 | |
| Reveal (pane) | 显示与收起 | Pane about how hidden items show and hide again. |
| show hidden items / hide them again | 显示隐藏项 / 再次隐藏 | “rehide” → 再次隐藏. |
| make room | 腾出空间 | |
| Hide Everything | 全部隐藏 | |
| Minimal menu bar (section of Reveal) | 极简菜单栏 | Was “Focus”, renamed so it is not confused with macOS Focus. |
| keep visible (pinned items) | 保持可见 | |
| Shortcuts (Rolltop’s pane, keyboard shortcuts) | 快捷键 | Not Apple’s Shortcuts app. |
| Columns / List (Menu Bar Items view) | 分栏 / 列表 | Was “Shelves”, renamed so it is not confused with the Shelf. |
| link (rolltop:// URL) | 链接 | |
| backup, automatic backup | 备份, 自动备份 | |
| Integrations | 集成 | |
| Item Spacing / spacing, selection padding | 间距 / 项间距, 选择边距 | |
| Menu Bar Appearance, style | 菜单栏外观, 样式 | |
| glass, material, tint, gradient, outline, pill | 玻璃, 材质, 色调, 渐变, 描边, 胶囊 | |
| notch / camera housing | 刘海 / 摄像头区域 | PLAN wording. |
| overflow menu | 溢出菜单 | Items that do not fit in the menu bar. |
| pt (points) | pt | Kept: “16 点” would read as 4 p.m. |

## macOS concepts (Apple zh-Hans)

| English | 简体中文 | Note |
|---|---|---|
| menu bar | 菜单栏 | |
| System Settings | 系统设置 | Paths: “系统设置 › 隐私与安全 › 设备控制和数据访问”. |
| Privacy & Security | 隐私与安全 | macOS 27 SecurityPrivacyExtension. |
| Device Control and Data Access | 设备控制和数据访问 | The permission Rolltop needs (TCC `kTCCServiceAccessibility`), named after its Privacy & Security pane, see below. Never “Accessibility” / 无障碍 / 辅助功能 in UI text. |
| Screen & System Audio Recording | 录屏与系统录音 | The optional permission for item images, named after its Privacy & Security pane. Never “Screen Recording” / 屏幕录制 in UI text. |
| Accessibility (the top-level pane: VoiceOver, Zoom…) | 无障碍 | Not where Rolltop’s switch is; Rolltop never names it. |
| Login Items, Login Items & Extensions | 登录项, 登录项与扩展 | The General pane is “Login Items & Extensions” in both languages. |
| Keyboard Shortcuts | 键盘快捷键 | System Settings › Keyboard (“键盘快捷键…”). |
| Focus, Focus filter | 专注模式, 专注模式过滤条件 | Apple calls Focus Filters 专注模式过滤条件. |
| Control Center | 控制中心 | |
| Notification Center | 通知中心 | |
| AirDrop | 隔空投送 | |
| Now Playing | 播放中 | Control Center module name; quoted (“播放中”) in sentences so it is not read as a state. |
| Wi-Fi | Wi-Fi | macOS 27 zh-Hans pane and Control Center module say Wi‑Fi (无线局域网 only in China-model variants); 无线局域网 stays as a search keyword. |
| Bluetooth, Battery, Sound, Clock, Displays | 蓝牙, 电池, 声音, 时钟, 显示器 | |
| Keyboard Brightness, Screen Mirroring | 键盘亮度, 屏幕镜像 | |
| Spotlight | 聚焦 | System Settings › Siri 与聚焦. |
| Input menu | 输入法菜单 | |
| Time Machine | 时间机器 | |
| Finder, Script Editor, Quick Look | 访达, 脚本编辑器, 快速查看 | |
| Shortcuts (Apple’s app), Siri | 快捷指令, Siri | |
| Apple Events | Apple 事件 | |
| Location access | 定位权限 | Location Services = 定位服务. |
| Calendars | 日历 | |
| Paste from other apps | 从其他 App 粘贴 | Apple: “从其他App粘贴” (Privacy & Security); our spacing rule adds the space. |
| Reduce Transparency | 降低透明度 | |
| Emoji & Symbols | 表情与符号 | |
| app | App | Apple writes App in zh-Hans. |
| built-in display, external display | 内建显示器, 外接显示器 | |
| power adapter, on battery power | 电源适配器, 使用电池供电 | |
| click, right-click, Option-click | 点按, 右键点按, 按住 Option 键点按 | Apple uses 点按. Key names stay (⌘, Option, Escape, Delete). |
| hover, scroll, swipe | 悬停, 滚动, 轻扫 | |
| Copy, Cut, Paste, Undo, Redo, Select All | 拷贝, 剪切, 粘贴, 撤销, 重做, 全选 | macOS menu terms. |
| Settings… / Quit Rolltop / About Rolltop | 设置… / 退出 Rolltop / 关于 Rolltop | |

## Permission names (macOS 27)

macOS 27 renamed the Privacy & Security panes where Rolltop is allowed. Rolltop names each permission
after the pane the user will look for, read from the system’s own string tables:

| Pane (System Settings › Privacy & Security ›) | 简体中文（系统设置 › 隐私与安全 ›） | Rolltop said before |
|---|---|---|
| Device Control and Data Access | 设备控制和数据访问 | Accessibility / 无障碍 |
| Screen & System Audio Recording | 录屏与系统录音 | Screen Recording / 录屏 |

- **Telling the user where to go** (the permission rows in onboarding and Settings › Permissions,
  messages without a button): the full path once, with “allow Rolltop”: “Allow Rolltop in System
  Settings › Privacy & Security › Device Control and Data Access.” / “在“系统设置 › 隐私与安全 ›
  设备控制和数据访问”中允许 Rolltop。”
- **Naming it in passing** (captions, notes next to a button that opens the pane or Permissions):
  the pane name alone. English writes it as a name, without quotes: “Needs Device Control and Data
  Access.” Chinese quotes it in sentences, since 和 would otherwise read as two things, and adds
  权限 where a noun is needed: 需要“设备控制和数据访问”权限。
- **Titles and menu items** (permission row titles, “Allow Device Control and Data Access…”): the
  name without quotes in both languages.
- The old names stay only as settings-search keywords (accessibility, screen recording, 无障碍,
  辅助功能, 屏幕录制), so people who search for them still find Settings › Permissions. 无障碍 is
  now the top-level Accessibility pane (VoiceOver, Zoom…), so it would send people to the wrong place.

## Style

- Menu items and buttons short; captions are full sentences ending in 。.
- Full-width punctuation in Chinese sentences (，。：；？“”（）), but › in settings paths.
- A space between Chinese and Latin words or numbers (第 1 步, 每 5 秒, 打开 Rolltop), none next to
  full-width punctuation.
- Never translate Rolltop, SF Symbol names, key names, identifiers, example commands or URLs.
- Formatted values (dates, durations, lists, percentages) come from formatters, not from catalogs.
- A placeholder that holds a formatted list (`%@` from `.formatted(.list…)`) or a list of
  translated names gets no padding spaces (显示%@, 除%@之外): the zh-Hans list format itself
  writes none (“Safari、时钟和Rolltop”). Single names and numbers keep the space (%@ 正在运行).
- Byte units stay KB, MB, GB, KB/s: zh-Hans ByteCountFormatter writes the same Latin symbols.

System terms above marked “macOS 27” were read from the system’s own zh_CN string tables
(System Settings extensions, ControlCenter.app, TCC) on this Mac, 2026-11-24; the permission
names on 2026-11-25 (macOS 27.2.1: SecurityPrivacyExtension `Localizable.loctable` keys
`ACCESSIBILITY` and `SCREENANDAUDIOCAPTURE`, its `InfoPlist.loctable` for Privacy & Security,
AccessibilitySettingsExtension for the top-level 无障碍 pane).
