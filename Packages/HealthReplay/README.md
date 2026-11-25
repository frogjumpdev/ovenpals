# HealthReplay：用真实的「健康」数据回放 App 的规则

把 iPhone「健康」App 导出的数据，按 App 的规则（PetCore，PRD v0.3）逐天算一遍：每天算不算运动、准不准时睡、
喂了哪些宠物、每周是不是自律周、宠物到几级，再把数据里容易让 App 看起来「算错了」的地方列出来。
不用装 App、不用等一周，几年的数据几秒钟就算完。在自己的 Mac 上跑，数据不上传。

## 用法

1. iPhone 上打开「健康」App → 右上角头像 → 「导出所有健康数据」，把得到的 `export.zip`（中文系统叫「导出.zip」）传到 Mac 上解压，
   得到 `apple_health_export` 文件夹。
2. 在仓库根目录运行（第一次要编译，约一分钟）：

```sh
swift run -c release --package-path Packages/HealthReplay health-replay ~/Downloads/apple_health_export \
    --bed 23:00 --wake 07:00
```

| 选项 | 意思 |
| --- | --- |
| `--bed 23:00` / `--weekend-bed 00:00` | App 设置里的入睡目标（周五、周六晚可以另设）；晚 30 分钟内睡着算准时 |
| `--wake 07:00` / `--weekend-wake 08:30` | 起床目标（周六、周日可以另设） |
| `--tz Asia/Shanghai` | 按哪个时区算，默认是这台 Mac 的时区 |
| `--to 2026-11-23` / `--from 2026-10-01` / `--days 56` | 回放哪几天。默认是导出前一天往前 8 周，从周一开始 |
| `--csv days.csv` | 另外把每天的结果写成表格（Numbers / Excel 能直接打开） |

## 输出

- 每周一块：这周几次运动、几晚准时，是不是自律周；每天的步数、运动、入睡、睡眠时长、起床、正念，和这天喂了谁。
- 结果：自律周和月度成就个数，每只宠物的天数、经验和等级。
- 要留意的地方（★ = 会改变 App 里看到或算出的结果）：
  - 入睡前的小睡（已和 App 一样不算入睡时间；列出来看按 PRD 原来的写法会不会被判准时）；
  - 入睡时间来自别的 App（比如 AutoSleep 比手表早记了一个小时）；
  - 几个 App 都记了的同一次运动（WHOOP、手表、Strava 各写一次，已和 App 一样只算一次，列出留了哪一条）；
  - 分成几段记的运动（同一个 App、同一种运动、中间停不到 10 分钟，已和 App 一样合成一次）；
  - 差一点算 20 分钟的运动（运动按显示的整分钟算，19 分 30 秒以上显示「20 min」、也算数）；
  - 正念 / 太极类运动（只喂 Matcha，不算一周的运动）；
  - 步数离 1 万很近；
  - 在别的时区记的数据（出行）。

## 和 App 不一样的地方

- 假定每个泡泡第二天 04:00 前都收下了；导出里没有请假和「手表记错了」，所以都当没有。
- 步数：和 App 一样，每天取记得最多的那一个来源（iPhone、手表、WHOOP 各算各的，不加在一起）。「健康」App 自己的
  每日总数会把几个来源合起来，所以可能比这里大。
- 只算 Apple 健康。Whoop 的三只宠物（Honey、Warm Milk、Protein Bar）要 Whoop 的数据，这里不算。
- 规则直接用 `Packages/PetCore`，读数据的方式照 `HealthPet3D/Health/HealthKitProvider.swift`（运动名称表是抄过来的，那边改了这边要跟着改）。

测试：`swift test --package-path Packages/HealthReplay`（Linux 上也能跑）。
