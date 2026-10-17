# 更新日志（douban-Piers 分支）

## 2026-10-17 · 同步上游 DenDyGH:main（5 个提交）

- **合并上游 5 个提交**（`41924b8` → `2b34e4a`），皮肤版本随之升至 **1.1.12**

### 上游更新内容

- **Skinshortcuts 图标精简**（`41924b8`）
  - 快捷菜单编辑里 5 个 Widget 设置项（宽高比 / 内容类型 / 排序方式 / 排序方向 / 数量限制）不再显示图标，界面更清爽
- **生成式 Includes 改用 Fallback 机制**（`45f08cf`）
  - 新增 `Includes_Fallbacks.xml` 空占位文件，移除旧 `Includes_Views_Fallbacks.xml`
  - skinshortcuts / skinviewtypes 脚本生成的缓存文件不再进仓库，改为启动时自动重建，避免更新冲突
  - Home、MyVideoNav、MyMusicNav 等 11 个窗口 XML 同步调整
- **新增 MyAnimeList 评分**（`8471ccc`）
  - 评分类型新增 MAL 选项，媒体信息页可显示 MyAnimeList 评分（数据来自 TMDbHelper）
  - 贴图包加入彩色 / 单色两版 MAL 图标
- **临时隐藏 Custom Hub Node**（`61e6c93`）
  - 自定义主菜单节点按钮暂不可用（待迁移 skinshortcuts v3），已暂时注释
- **版本号提升**（`2b34e4a`）：1.1.11 → 1.1.12

### 分支特有处理

- **豆瓣评分与 MAL 评分共存**：`Includes_Object.xml` 冲突已解决，豆瓣（Douban）与 MyAnimeList 两套评分行同时保留
- **Textures.xbt 无损合并**：按 XBTF v2 格式字节级拼接，将上游 2 个 MAL 图标（彩色 104×64 / 单色 52×32）并入本分支贴图包，豆瓣图标完整保留，全部 1361 个条目校验逐字节一致
- 至此本分支在 1.1.12 基础上同时支持 **豆瓣 + MyAnimeList** 双评分源
