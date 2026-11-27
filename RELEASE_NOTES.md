## English

### Highlights in v1.4.3

- **Built-In AI Brand Logo Finder (`AILogoFinderService` + Native CoreGraphics Normalization)**: Integrated the complete multi-stage AI brand logo workflow directly into the macOS app so any newly added wet-shaving brand can get a crisp, verified logo in seconds:
  1. **AI Web Source Discovery**: Uses your configured AI API (with web search / Google Search) to locate authentic official websites (including brand subpages) and verified direct CDN logo URLs without blind `<brand>.com` guessing.
  2. **Smart Header / JSON-LD & Wayback Machine Rescue**: Extracts official `<header>` brand logos and JSON-LD metadata (automatically ignoring country flags and SVGs), and automatically falls back to Wayback Machine snapshots when an artisan site is paused or returns HTTP 402/403.
  3. **AI Vision Self-Audit & Mid-Gray Visual Review**: Renders harvested candidates into a numbered mid-gray contact sheet for optional AI Vision authenticity checks (filtering out unrelated hotels, parked domains, and default Squarespace placeholders; gracefully degrades on text-only models).
  4. **Native CoreGraphics 256px Normalization**: Automatically trims excess transparent, white, or black margins, rejects blank/uniform placeholders, scales the long edge to `256px` while preserving original aspect ratios, and offers live **Auto/White/Black Trim + Circle Mask** refinement across Light, Mid-Gray, and Dark card previews before saving permanently to `CustomLogos/`.
- **Single-Brand & Batch Missing-Logo UI**: Added **"AI Find Logo"** right inside the Gear Editor next to Custom Icon, and **"AI Find Missing Logos"** in Settings to batch-discover and visually approve logos for all monogram-only brands in one mid-gray review grid.
- **24 Upgraded Curated Built-In Brand Logos & Verified Mappings**: Upgraded and standardized 24 built-in brand logos (`RazoRock`, `PAA`, `House of Mammoth`, `HAGS`, `WestMan`, `Turn-N-Shave`, `Wolfman`, `Karve`, `Lambda`, `Yaqi`, `Thayers`, `Clubman Pinaud`, `AKA`, `Astra`, `Semogue`, `DSCosmetic`, `TwoFace Brothers`, `ROKYHOWS`, `Wizamet`, `Ethos Grooming`, `Declaration Grooming`, `LAXO`, `Arno`, `Amonatura`), corrected 9 brand domain mappings, aligned all 13 shorthand/alias bundled keys, gave `Astra` and `Wizamet` dedicated standalone logos (no longer mapped to Gillette), and added smart light-mode inversion for pure-white transparent line-art marks (e.g., `House of Mammoth`).

---

## 简体中文

### v1.4.3 更新亮点

- **内置「AI 智能品牌找图」完整引擎（寻源 → 页头/Wayback 提取 → 视觉自检 → 256px 规范化）**：将本次实测高命中的 AI 找图方法论完整原生集成进 macOS 应用，后续新增任何小众/手工湿剃品牌都能一键配齐高清正版标：
  1. **AI 联网寻源**：调用已配置的 AI 接口（含联网/Google 搜索）精准定位品牌官网（含子页面如 `aura-craft.com/laxo/`）与可信直链图，彻底拒绝瞎猜 `<品牌>.com` 与内网 SSRF 风险。
  2. **官网页头 / JSON-LD 与 Wayback 归档救援**：优先提取 `<header>` 品牌主标与 JSON-LD 元数据（自动跳过国旗与 SVG），当手工作坊官网暂停或返回 402/403（如 Declaration Grooming）时自动从 Wayback Machine 归档页提取官方原标。
  3. **AI 视觉自检与中灰底验收**：支持将候选图拼成带编号的中灰底预览交由视觉模型把关真伪（过滤无关旅馆、抢注站与默认占位块；纯文本模型自动静默降级为高质量排序）。
  4. **原生 CoreGraphics 自动去边与 256px 规范化**：纯 Swift 原生自动裁掉多余白边/黑边/透明边、拦截纯白空白图、长边等比缩放至 `256px` 无冗余元数据 PNG，并提供**浅色 / 中灰 / 深色三底色实时验收**与**去边模式 / 圆形裁切**一键微调，确认后永久写入 `CustomLogos/` 并同步云盘。
- **单品牌「AI 找图」+ 设置页「AI 批量补全缺失品牌 Logo」**：器材编辑页「更换图标」旁新增「AI 找图」入口；设置页「器材库与品牌图标」新增「AI 补全缺失品牌 Logo」，自动扫描全库仍显示字母圈的品牌并生成中灰底批量验收网格，一键勾选落盘。
- **24 款精选内置品牌 Logo 全面焕新与映射修正**：逐张人工验收升级 24 款内置品牌 PNG（`RazoRock`、`PAA`、`House of Mammoth`、`HAGS`、`WestMan`、`Turn-N-Shave`、`Wolfman`、`Karve`、`Lambda`、`Yaqi`、`Thayers`、`Clubman`、`AKA`、`Astra`、`Semogue`、`DSCosmetic`、`TwoFace`、`ROKYHOWS`、`Wizamet`、`Ethos`、`Declaration Grooming`、`LAXO`、`Arno`、`Amonatura`）；修正 9 个品牌域名并补齐全部 13 组简称/别名内置文件映射；彻底取消 `Astra` 与 `Wizamet` 借用 `gillette.png` 的旧规则改为独立专属标；补充浅色模式下纯白透明线稿标（如猛犸象）的智能反相显示。
