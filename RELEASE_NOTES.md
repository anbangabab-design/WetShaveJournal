## English

### Highlights in v1.4.0

- **Unified macOS & Windows Repository & Releases**: macOS (`.pkg`) and Windows (`.exe` / `.msi`) installers now build and publish together from a single GitHub Release page, with each platform's built-in updater automatically selecting the matching installer and localized release notes.
- **Cloud Drive Bidirectional Auto-Sync (`journal.json` & `CustomLogos/`)**: Bind any synced folder (Google Drive, iCloud Drive, OneDrive, etc.) in **Settings → Data & Sync** to automatically merge entries, gear rules, deletion tombstones (`deletedEntryIds`), unknown extension fields, and custom brand logos across macOS and Windows. Includes silent sync on launch, 2-second debounced auto-sync after edits, automatic local backup before overwriting, and atomic temp-file replacement.
- **SOTD Photo / Image AI Recognition**: Drop, pick, or paste (`⌘+V` on macOS / `Ctrl+V` on Windows) your SOTD photo right inside the New / Edit SOTD dialog. Photos are automatically compressed (`≤ 1280px` JPEG) and sent to your configured OpenAI-compatible vision model (e.g. Gemini / GPT) with your in-hand gear library context to accurately prefill gear fields and suggest the next blade use count.
- **Automatic Official Brand Logo Fetching on Windows**: Windows now automatically fetches official brand logos into `LogoCache/` (with anti-Etsy/marketplace domain filtering) while preserving `CustomLogos/` and sharing custom logos with macOS.

---

## 简体中文

### v1.4.0 更新亮点

- **macOS & Windows 双端合库统一发版**：macOS（`.pkg`）与 Windows（`.exe` / `.msi`）安装包正式整合至同一仓库与统一 GitHub Release 页面发布，双端内置更新检查会自动挑选对应平台安装包并按系统语言展示中英文更新说明。
- **云盘 `journal.json` 与自定义品牌图标双向自动同步**：在「外观与设置 → 数据与同步」绑定任意云盘同步目录（Google Drive / iCloud / OneDrive 等）即可实现 Mac 与 Windows 双端智能双向合并（按 ID 与 `updatedAt` 合并日记与器材规则、日期+核心器材指纹防重、`deletedEntryIds` 删除墓碑防复活、无损保留未知扩展字段，并增量同步 `CustomLogos/`）。支持启动静默同步、保存后 2 秒防抖自动同步、写入前本地自动备份与原子替换。
- **SOTD 拍照 / 传图多模态 AI 自动识别**：在「新建 / 编辑 SOTD」顶部新增拍照/传图识别入口，支持点击选图、拖拽照片与剪贴板粘贴（Mac `⌘+V` / Win `Ctrl+V`）。发送前自动压缩至长边 `≤ 1280px` JPEG，并携带在手器材库摘要调用视觉大模型精准匹配并预填装备，自动建议刀片下一次使用次数；遇到纯文本模型时给出清晰切换提示。
- **Windows 自动联网抓取品牌官网 Logo**：Windows 端现已支持自动抓取湿剃品牌官网图标并缓存至 `LogoCache/`（内置反 Etsy / 平台域名黑名单，绝不覆盖 `CustomLogos/`），并与 Mac 端共享自定义品牌图标。
