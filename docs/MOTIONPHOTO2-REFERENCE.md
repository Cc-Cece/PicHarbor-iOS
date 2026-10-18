# MotionPhoto2 本地参考记录

记录日期：2026-10-19。以下来自本地文件阅读，不代表在 iOS 或当前 gpmc 上传链路上已经验证。

## 来源快照

- 本地目录：`C:\Users\Kanbara\Code\vscode\MotionPhoto2`，作为只读参考。
- 本地 HEAD：`ff46699215f1071ada579140d73994a4be29a399`。
- 阅读时工作树干净；本次未修改该目录。
- 当前本地 `origin`：`https://github.com/PetrVys/MotionPhoto2`。用户称已 fork，但本次没有据此推断另一个远端地址，也没有执行远端操作。
- 本地许可证：MIT，Copyright (c) 2024 Petr Vyskocil。若后续复制或改编代码，需保留对应版权与许可，并记录实际采用的文件和提交。

## 已阅读的实现线索

| 文件 | 与本项目相关的内容 |
| --- | --- |
| `README.md` | 从 HEIC/JPG 与视频创建 Motion Photo v2/v3；描述 iPhone Live Photo 关键帧迁移、文件名/EXIF 配对及 HDR 限制 |
| `Muxer.py` | 区分图像/视频类型、读取和合并 XMP、读取 Live Photo 关键帧时间、写入资源长度与偏移、生成合成文件 |
| `constants.py` | XMP 模板、GCamera/Container/Item 命名空间、时间戳字段、`mpvd` 等容器常量 |
| `SamsungTags.py` | Samsung 尾部结构、长度与偏移，以及 HEIC 视频数据的 `mpvd`/`sefd` 封装 |
| `utils.py` | 通过 ExifTool 检测 Motion Photo、读取已有动态视频等辅助能力 |
| `motionphoto2.py` | 桌面命令行/GUI、目录遍历、文件名或元数据配对、覆盖/删除等选项 |

README 描述其输出看起来兼容 Google Photos/Samsung Gallery，并记录了特定 HEIC/HDR 场景的限制。这些是参考项目的描述，不扩展为当前应用的兼容承诺或所有设备上的结论。

## 移植边界

- `requirements.txt` 列出 `lxml`、`PyExifTool`、`Gooey`、`six`；说明要求另行安装 ExifTool。
- `Muxer.py` 通过 `ExifToolHelper.get_metadata/execute` 处理图像和视频元数据，并有桌面临时文件工作流。
- 因此它不是仅依靠现有 gpmc 纯 Python 依赖就可直接运行的 iOS 模块。后续需独立评估替代元数据读写、原生库或可移植封装核心。
- 当前代码会把部分媒体读入内存并合并；iOS 实现需要另行评估峰值内存、文件大小边界及有界暂存，不能照搬整批桌面处理方式。
- 命令行中的覆盖原文件、删除源视频等选项不作为 iOS 行为依据。iOS 原件处理必须遵守应用自己的核验和删除授权流程。
- 从 PhotoKit 取得的配对资产不必复用桌面目录扫描；参考重点是封装与元数据语义。
- 此项目不能直接证明“苹果原始资源配对方式”的 Google Photos 云端关联能力；该目标仍需单独验证协议与恢复闭环。

## 后续需核实，当前未执行

- 标准容器格式与 Samsung 扩展中，哪些字段是目标云端兼容所必需的。
- 关键帧时间的提取、单位和含义是否覆盖不同 iPhone/iOS 样本。
- 原有 XMP、方向、拍摄时间、音频和 HDR 数据的保留情况。
- HEIC/JPEG + MOV/MP4 样本经封装、gpmc 上传、云端播放及下载后的结果。
- Motion Photo 拆解与苹果 Live Photo 恢复能力，以及和资源完整性证据的关系。

本轮仅建立参考记录，未安装依赖、运行工具、引入代码或制定完整实施计划。
