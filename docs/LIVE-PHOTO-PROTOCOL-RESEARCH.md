# 原始 Live Photo 云端配对研究（2026-10-19）

本轮为公开资料与源码核对；未修改应用、调用真实上传或提交接口、使用用户凭据，未执行参考仓库的程序。参考仓库只读快照位于被忽略的 `build/research-live/`。

以上记录接入前的研究过程。用户随后授权将可集成方案加入测试版；0.2.4 的实际实现、构建与验收状态另见 DEVELOPMENT-ACCEPTANCE.md 和 LIVE-PAIR-TESTING.md，不将下文研究时的 apple_pair=false 当作新版能力状态。

## 结论修正

此前“当前应用没有实现配对”仍属实；“没有可参考的云端关联协议”已不再符合此次检索结果。xob0t/gotohp 有新建配对和已有静态图补动态的具体实现；g8row/PhotosBackup 有独立 Swift 实现、协议研究和作者报告的真机结果。应以这些实现为依据开展移植验证，不继续把格式转换工具当作唯一方向。

公开代码及他人测试不等于 PicHarbor 已验证，当前 `apple_pair=false` 保持不变。

## 已检查项目与快照

| 项目 | 本地快照 | 已核对内容 | 参考定位 |
| --- | --- | --- | --- |
| [xob0t/gotohp](https://github.com/xob0t/gotohp) | `97a5dc02db81f5571ce6b586f478600fcd44dd89` | `core/create_media_items.go`、`core/livephoto_upload.go`、分类与元数据代码 | 首选协议实现参考；MIT |
| [g8row/PhotosBackup](https://github.com/g8row/PhotosBackup) | `3c88269e18b9d4515e97d846c5816bd836285c3e` | `GPMC/Core/GPMCClient.swift`、`App/Sources/MediaExport.swift`、协议测试及 docs | 首选 iOS 资源选择与官方客户端匹配参考；仓库 LICENSE 为 MIT |
| [tqmane/gunshot](https://github.com/tqmane/gunshot) | `a2992a0c67194a7ac32bf3382f89ef80f99fb510` | Go overlay 的上传门面、Live Photo 测试、路由说明 | 官方客户端集成参考；运行形态涉及注入/越狱或改包，仓库 GPL-3.0-or-later，不直接照搬 |
| [Voryn-Labs/Cloudified](https://github.com/Voryn-Labs/Cloudified) | `0fe274ca953bfa950bfd3fdf3c1c9575e00a33fc` | GooglePhotosProviderAdapter、公开 FAQ | 双资源同一远端标识核验、失败显式处理的参考；不能凭设置选项认定已支持全部配对场景 |

## 最有价值的协议证据

[gotohp 提交构造](https://github.com/xob0t/gotohp/blob/97a5dc02db81f5571ce6b586f478600fcd44dd89/core/create_media_items.go)与[上传编排](https://github.com/xob0t/gotohp/blob/97a5dc02db81f5571ce6b586f478600fcd44dd89/core/livephoto_upload.go)体现两条路径：

- 新建：分别传照片和配对视频的原始字节，保留两份原始上传响应，在同一创建媒体请求中使用 blueprint 的字段 24 `livePhotoInfo` 关联视频响应和视频 SHA-1。照片仍使用自己的 SHA-1。
- 已有静态图补视频：以视频为提交主体，通过字段 9 `reconcileInfo`（Phodeo）指定静态图 SHA-1。不能把视频作为普通独立媒体提交后就宣布配对完成。

这些操作沿用 PicHarbor 当前 gpmc 使用的创建媒体 RPC。Python gpmc 当前普通 `commit_upload` 没有字段 9/24，直接更新普通上传接口不会自动获得原始配对。

资料层次需要区分：[PhotosBackup 的早期协议研究](https://github.com/g8row/PhotosBackup/blob/3c88269e18b9d4515e97d846c5816bd836285c3e/docs/live-photo-paired-upload.md)明确是静态分析；其[后续匹配规则记录](https://github.com/g8row/PhotosBackup/blob/3c88269e18b9d4515e97d846c5816bd836285c3e/docs/google-photos-backed-up-rules.md)、0.3.7 发布说明和协议测试注释报告了配对、动态播放及配额方面的真机结果。不能将静态研究里尚未确认的描述或后续单设备结果扩大为所有模式保证。

## 对双项显示的解释与限制

PhotosBackup 作者的设备研究指出，官方客户端会比较它自己为本机资产选择的文件 SHA-1：未编辑资源使用原件，苹果编辑资源使用渲染版本，Google 非破坏性编辑还涉及 adjustment base。当前 Motion Photo 改变文件结构，因此难以匹配原图片字节；这是与用户观察相符的机制依据，不是 PicHarbor 已完成的协议实验。

原始配对保留照片字节，有望让云端资产匹配本机原件；经编辑版本必须使用相应照片及配对视频，不能只保持文件名。双版本保留也可能形成两个实际内容不同的云端项目，这与错误重复需分别表达。

该项目还报告：在其测试的 Google Photos/iOS 版本中，从 Google Photos 保存回设备的照片，可能在已具有相同云端字节的情况下仍不被判定已备份。不能承诺仅实现配对就解决取回后全部识别行为。已有本机原件时再次导入是否新增资产、官方客户端是否认为已在设备上，均需单独真机检查。

旧 Motion 封装件与原始图片 SHA-1 不同。基于源码推断，按原始图片哈希建立配对不能直接保证旧封装件自动合并；迁移必须另行设计，继续遵守不自动删除云端内容的边界。

## 适合 PicHarbor 的验证顺序（建议，未执行）

1. 保留 SwiftUI、PhotoKit、SQLite 和原生文件型后台传输，Python 适配层增加原始配对请求。无需为了采用 Go 代码而立即更换整套引擎。
2. 首先选择未编辑 HEIC + MOV 专用样本，分别覆盖全新资源和云端仅有原图的补视频路径；保留每份原始响应及不明提交状态。
3. 关联核验包含：照片常规哈希查询、视频按 `sha1MediaType=PhodeoMovie(2)` 查询，二者指向同一媒体身份，并检查 associated media 的一致性及动态播放。Cloudified 适配器已有“两个哈希必须返回同一标识”的防线。
4. 分别核对谷歌客户端单项显示与已备份标记、声音/关键帧/方向/HDR、官方取回表现，以及实际配额状态。三个画质模式各自验证，不从设备声明或静态字段推断免费存储已成立。
5. 未编辑样本通过后再扩展编辑版本、已有云端视频、提交中断及重试。gotohp 对“只有独立视频已存在”的反向关联明确保留未知边界，不能无条件视为已完成或猜测协议。
6. 在该应用的证据闭环完成前，不开启 Live Photo 自动本地清理，不把研究项目的官方客户端空间清理结果当作本应用删除依据。

## 复用边界

优先从 MIT 项目的具体文件取证并记录来源；如后续复用代码，保留版权和许可证。gunshot 的 GPL 代码与集成方式单独评估，不能因同样使用 gotohp 就假定整个仓库都是 MIT。本轮没有复制参考项目代码进入生产目录。
