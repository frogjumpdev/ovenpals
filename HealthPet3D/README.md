# HealthPet 3D（3D方案 · 测试版）

现在仓库里唯一的 App（Bundle ID `com.ovenpals.app`，桌面名字「Ovenpals」；HealthPet 只是内部代号，target 和目录名还叫 HealthPet3D）。2D 版 HealthPet 已在 2026-11-08 停用，见仓库根目录 README。
界面是最终版 v3「干净版」· Mountain Jade 配色（白天）/ 森林夜（黑夜），宠物是 3D方案 的切片宠物，带 41 个表情。

## 在 Mac 上跑起来

1. 终端进入仓库：`cd ~/Developer/health-pet`
2. 生成 Xcode 工程：`xcodegen generate`（XcodeGen 在 `~/Developer/tools/xcodegen-dl/xcodegen/bin/xcodegen`）
3. 打开 `HealthPet.xcodeproj`，左上角的 scheme 选 **HealthPet3D**，设备选 **iPhone 18 Pro**（iOS 27.0）
4. 按 ⌘R 运行。模拟器里默认用 Demo 数据；右上角「…」→ Settings → Test build → Data 可以换成 Real data（Apple 健康 + 连上的 Whoop，见「用真实 Whoop 数据测试」一节）
5. 测完马上退出：模拟器 ⌘Q，Xcode 里按 ⌘. 停止（Mac 会发热）

命令行构建（不开 Xcode）：

```
xcodebuild -project HealthPet.xcodeproj -scheme HealthPet3D \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

模拟器截图（不开 Simulator.app，结束时自动关掉模拟器）：上面的命令加 `-derivedDataPath build/dd` 构建，然后
`HealthPet3D/tools/sim-shots.sh <模拟器 UDID> <输出目录>`。每次启动的日志在输出目录的 `console-*.log`，
`[pet]` 开头的行是宠物网页的加载用时和报错。

调试开关（只在 Debug 构建里有效，加在启动参数里，截图脚本就是这么用的）：

| 参数 | 作用 |
|---|---|
| `-3d.onboarded NO` / `-3d.tourDone NO` | 再走一遍首次打开 / 主页导览 |
| `-hp3dFirstOpenStep health\|reading\|pets\|bedtime` | 首次打开直接停在某一页 |
| `-hp3dTour 1\|2\|3\|tryit` | 主页导览直接停在某一步 |
| `-hp3dNote asleep\|rest\|week\|day` | 主页点开某个说明（day = 日历行里的一天） |
| `-hp3dFeed all\|workout\|steps\|night\|load` | 宠物准备好 9 秒后自动吃气泡 |
| `-hp3dRegrow YES` | 今天吃过的食物长回来 |
| `-hp3dBookAll YES` | 打开 Today 页 1.5 秒后吃掉今天的食物（看入账后的标签） |
| `-hp3dRoute today\|pets\|memories\|settings\|share\|pet:toast…` | 直接打开某一页 |

## 结构

```
HealthPet3D/
  App/          入口、导航、HomeState（每天第一次醒来、导览看过没有、新宠物小圆点、外观、名字）、通知
  Design/       配色（Jade）、字体（SF Pro Rounded）、卡片和按钮
  Pet/          Pet3D（20 只宠物）、RosterPet（宠物名单和对应的运动）、PetStage（活的 3D 宠物，WKWebView 里跑 pet.html）
  Model/        AppModel（汇总所有数据源、算出宠物状态）、Feeding（食物气泡、点一下入账、本周格子）、
                DayFacts（状态区、日历行、宠物说的话）、Progress
  Health/       数据源：HealthKit、Whoop（走 Supabase 后端）、Demo
  Store/        PetStore：存在手机上的领养日、回忆、自律周、运动记录、请假日、健康数据缓存；
                CreditBook：吃掉（入账）了哪些食物，每条一行记录；DressUpStore：装扮的积分、抽到的装饰、每只宠物的穿法
  Backend/      Supabase 客户端（Whoop 登录和同步）
  Features/     Home · Today · Pets（含宠物详情）· Dress up（衣柜、礼物卡）· Share · Memories · Settings
  Sound/        Sounds（音效播放）、Haptics（触感）、Cues（每个时刻放哪个声音、什么时候、配什么触感）
  Resources/    Assets（20 只宠物 × 正常/开心两张静态图、App 图标）、PetWeb/pet.html、
                Sounds/（36 个 wav）、Haptics/（6 个 AHAP）
  PetWeb/       pet.html 的源码和构建脚本（不进 App）
```

规则和计算（自律周、宠物等级、精力、成就账本、分享称号……）在 `Packages/PetCore`，可以单独跑测试：`cd Packages/PetCore && swift test`。

## 3D 宠物（pet.html）

- 一个离线网页：open-bot-avatar 0.1.2（MIT）+ 3D方案 表情引擎 engine.js + 活宠物导演 live.js（和预览页同一份代码，没有改）+ `PetWeb/src/bridge.js`（App 和宠物之间的接口）。
- 只有首页、宠物详情和 Dress up 的宠物是活的（同一个网页，在页面之间传递）；Pets 格子和分享卡用静态图（由同一个 3D 宠物渲染）。
  穿了装扮的宠物在 Pets 格子和分享卡上用 App 现拍的图（`Pet/PetSnapper.swift`，见下面 Dress up 一节）。
  网页启动要一点时间，这期间同一位置先显示静态图，宠物画出来后淡掉；iOS 在后台回收了网页进程时会自动重新加载。
- 改了 `PetWeb/src/` 以后：`cd HealthPet3D/PetWeb && npm install && npm run build`，会重新生成 `Resources/PetWeb/pet.html`。
  重新渲染静态图：`node tools/stills.js ../Resources/PetWeb/pet.html <输出目录>`（需要 Playwright）。
  重新渲染 App 图标（浅色 / 深色 / 着色三张，直接写进 AppIcon.appiconset）：`node tools/appicon.mjs`。
- 表情规则沿用预览：点一下随机害羞 / 吓一跳 / 歪头 / 眨眼，连点 3 下被挠痒，6 下晕乎乎，按住被摸摸；没人碰 45 秒犯困、2 分钟睡着；
  每天第一次打开播「醒来」；吃食物时眼睛跟着碎屑、嚼三下再吞（`Pet.feed`）；吃完所有食物「开心跳」；睡觉时间一到很快睡着；没电（元气低）时偶尔露出「有点累」。

## 按 PRD v0.2 做了什么（2026-11-08）

PRD：「健康宠物 3D 方案 · PRD v0.2」（Claude Doc）。设计稿：项目文件 `健康宠物/3D方案/ui-final-v3/home-v3.2-share-v2/`。

- **主页 v3.2**：状态区没有数字，只有「月亮 + 入睡时间 + 勾」（准时才打勾，晚了只显示时间）和一条休息条；HRV 条去掉；
  Apple 用户的休息条是 App 自己估的 Rest，Whoop 用户是 Whoop 恢复分，右边标 WHOOP。负荷泡泡只在有 Whoop strain 时出现。
  「…」里只有 Settings（好友占位去掉）。一周固定周一开始。
- **宠物慢变状态（元气 / 平常 / 没电）**：按最近 7 天的准时夜、运动次数、Rest 均值各占三分之一（`PetCore/PetEnergy.swift`）。
  元气多哼歌、开心跳、星星眼；没电多打哈欠、发呆、伸懒腰，脚下椭圆变淡，点它先给你打气。只改待机动作和椭圆，不改任何数值。
  Settings → Test build → Pet energy 可以手动切三档看效果。
- **面包人等级 = 累计自律周数**；亲密度（拍拍 / 零食）不再用，喂食只是动画。
- **能量棒** 改成「连续两天训练量匹配恢复」（2026-11-14 又改成「红灯天好好休息」，见下面一节）。
- **请假日**：Today 的 Sleep 卡上可以把昨晚标成请假（每周 1 次，算一个准时夜，再点一下取消）。
- **睡眠目标**：半小时档位（20:00–02:00），周末（周五、周六晚）可以单独设；设置会保存。
- **Pets** 只平铺已解锁的（面包人第一，其余按等级），没遇见的收进一个「+N」入口；没连 Whoop 不显示补给小队。
- **Memories = 成就账本**（`PetCore/Ledger.swift`）：每个自律周、月度成就、每次解锁、Lv 10 / 20、30 / 100 个准时夜、100 次运动、第一个 2 万步日、在一起 30 / 100 / 365 天。
- **分享卡 v2**：印章 + 身份标题（如 Early-to-bed Runner，`PetCore/ShareIdentity.swift`）+ 一行人话 + 三只宠物（主宠居中骄傲挺胸、都带 Lv）
  + 累计自律周数做最大的数字 + 名字 · 日期 · HealthPet。达成自律周时，主页庆祝完自动弹出这张卡（Share / Not now）。
- **首次打开**：连 Apple Health → 「Your last 30 days」展示过去 30 天已经解锁的宠物和等级 → 选目标入睡时间 → 主页。
- **早上揭晓**：每天第一次打开，醒来之后：准时 = 骄傲挺胸 + 「On time last night ✓」；有宠物升级 = 开心跳；断签回来 = 给你打气。
- **接上的表情**：困惑（今天没拿到手表数据）、星星眼（新宠物加入）、骄傲挺胸（早上揭晓）、给你打气（断签回来 / 差一点到 1 万步）、
  喜欢你（在一起 7 / 30 / 100 / 365 天、第一个自律周）。「有点失落」不用。
- **两条通知**（Settings → Notifications，默认关）：睡前 30 分钟「Toast is getting sleepy」、起床时间「See how last night went」。
- **活宠物只有一个 WKWebView**：App 启动就在后台加载 pet.html（预热），主页和宠物详情轮流用同一个（`Pet/PetStage.swift`）。

## 按 v3.3 / v3.4 做了什么（2026-11-09）

PRD v0.2 §4.3 / §4.4 / §6 已定。设计稿：`健康宠物/3D方案/ui-final-v3/` 下的 `home-food-v2/`（气泡和收获）、
`home-guide-v1/`（引导和说明）、`today-cal-v1/00`（Today 六处改动 + 日历行 B）；Figma 02 的 98:50 和 120:2。

- **点击 = 入账**（`PetCore/Credits.swift` + `Store/CreditBook.swift`）：手表数据先变成食物气泡，点一下才算进本周、日历、
  宠物等级和 Memories；没点的第二天 04:00 自动入账（记录上写「Collected for you」）。还没入账的数据不计数：
  运动不算、步数最多算 9,999、昨晚的入睡时间不算准时。Today 的数字照常显示真实数据，只是勾是灰的。
- **食物气泡 B 轻泡 · 实心**：50 pt 卡片色圆，颜色只在图标和数字上，没入账时右上角一个灰点；
  运动（最多两个，带分钟数）、步数（≥ 1 万）、昨晚（月亮 + 入睡时间）、Whoop 负荷。消耗气泡去掉了。
- **收获动画**（`Features/Home/FeedFX.swift`，时间按 11-08 分镜）：气泡果冻一下、爆成 7 粒碎屑、一粒粒吸进嘴里、
  宠物嚼三下吞下、头边冒出「Chili +1」、一个小点从脚下飞到本周那一格，格子填满并跳一下；全吃完开心跳。
  晚睡和 Whoop 负荷不进格子，小点飞到 Memories 图标。
- **本周进度行**：状态区下面「This week」：跑步图标 + 3 格、月亮 + 5 格（请假夜是虚线格）。
- **名词标签**：底栏 Pets · Today · Memories，状态区 Asleep · Rest · This week，都带图标（v0.3 起 Apple Watch 用户的第二行是 Slept）。
- **点一下有说明**：Asleep、Rest、This week（逐格解释）和日历行的每一天都会弹出小卡片。
- **日历行 B**：圆点换成 11 pt 的跑步 / 月亮图标，没有的那天是短横。
- **首次打开 6 页**：你好 → 连 Apple Health（说明会读哪四类数据）→ 读取进度 → 「You’ve already met two pets」→ 入睡时间（可分周末）→ 主页（v0.3 起入睡时间放到读取前面）。
- **宠物 3 步导览**（`Features/Home/HomeTour.swift`）：首次进主页、宠物醒来之后，压暗其余部分、只亮一块，宠物用一句话讲
  食物 → 记录 → 底栏，最后一个真气泡上「Tap to feed Toast」。随时可以 Skip；「…」里的「Show me around」可以再看一遍。
- **Today 六处改动**：日期行；Asleep 卡 + 「✓ Early night」；运动卡 + 「✓ Workout」+ 距离和配速；步数「of 10k」；
  This week 用胶囊格 + 还差几次；Rest 条。每张卡点一下都有说明。
- **Memories** 多了「Collected」：每次吃掉的食物一行（「Chili +1」或「Chili Lv 15 → 16」）。

## 按 PRD v0.3 做了什么（2026-11-12）

PRD v0.3 §10.3「已定、还没做」分四批做，这是第 1 批「只读原值，不造分数」：App 不再自己算任何健康分数，只读 Apple Watch、Whoop 记下的原值。

- **睡眠按夜分组**（`PetCore/SleepNights.swift`，有单元测试）：Apple 健康只给一段段睡眠片段，App 只决定哪些属于同一晚：
  18:00 到第二天 18:00 开始的片段算一晚，记在醒来的那天；入睡 = 第一段的开始（入睡前的小睡不算，见下），
  时长 = 各段相加（重叠只算一次），醒来 = 中午前开始的最后一段的结束。以前按片段结束的日期归天，零点前入睡会被记晚。
- **Whoop 的入睡和醒来时间直接用 Whoop 的**：服务器把主睡眠的开始、结束存进 `daily_snapshots.sleep_onset / wake_time`
  （迁移 `20261112000000_whoop_sleep_times.sql`）并传给 App，合并时 Whoop 优先。
- **主页状态区第二行**：Apple Watch 用户 = 床图标 + Slept + 昨晚睡了多久（7h 30m）；Whoop 用户仍是 Whoop 恢复条（不带数字，标 WHOOP）。
  说明小卡和导览第 2 步的话跟着分开写。Today 只给 Whoop 用户留 Recovery 一行。
- **元气只看准时夜和运动次数**，各占一半（`PetCore/PetEnergy.swift`）。
- **删掉的估算**：Rest（HRV + 睡眠时长）、每日负荷、宠物每天的心情（`DailyMetrics`、`PersonalBaseline`、`PetStateEngine`）。
  宠物舞台和点它说的话只跟元气三档走；Settings 测试组的「Demo day」心情开关去掉。
- **上一周补庆祝**：上一周靠周一 04:00 自动入账才凑满自律周时，下次打开也会庆祝并弹出分享卡，卡上是上一周的日期。
- **本周小卡**底句加半句 “Nights count on the morning you wake up.”
- **没有睡眠数据**：30 天里一晚睡眠都没有时，Asleep 的说明小卡换成 “I can’t see your sleep yet. Wear your watch to bed and the moon shows up.”；
  连了 Apple 健康却连续 3 天以上什么数据都没有时，Settings 的 Apple Health 组多一行，说明去「健康」App 的哪里打开权限。

### 第 2 批：界面和设置（2026-11-12）

- **首次打开顺序**：你好 → Apple 健康（说明会读哪四类数据；底句改成 “…your health data never leaves it, and you can turn any of
  these off in the Health app.”）→ 入睡时间 → 读取最近 30 天 → 已经认识的宠物 → 主页。入睡时间放到读取前面，第 ⑤ 页的等级就是主页上的等级。
  一只都没认识时不再跳页，只是 Toast 说一句；30 天里没有睡眠时，这句换成 “I can’t see your sleep yet…”。
- **睡前提醒只问一次**：第一次吃掉准时的月亮之后，宠物问 “Want me to yawn at you 30 minutes before bed?”（Not now / Sure），
  点 Sure 才弹系统的通知权限。不管答什么都不再问，开关在 Settings。
- **24 / 12 小时制**（`Model/ClockStyle.swift`）：Settings → Look → Time format。没选过就跟手机走。所有时间都走 `Format`：
  主页和 Today 的大数字后面跟一个小号灰色的 PM；月亮气泡只写 10:48、不写 PM。
- **「手表记错了」**：Today 的 Asleep 卡上，晚睡（或没记到）的那晚下面有 “Watch got it wrong?”，选真正的入睡时间，
  只有算准时才能保存；每月 2 次，和每周一次的请假分开；保存后显示手表原来记的时间和 Undo。只改这晚准不准时，不单独进流水。
- **颜色对比度**（PRD §8.1）：次要文字 #626B5D，所有常显的标签都用它；夜间不活跃色 #7E877A；空格子 1 pt #7D857A 描边；
  白天柠檬绿的格子和 Whoop 恢复条加 1 pt #8A8331 描边。
- **动态字号**：Today、Memories、Settings、首次打开跟系统字号走（`.scaledFont`）；主页最多放大两档；分享卡和宠物格子不变。
- **减弱动态效果**：气泡不浮动；收获改成气泡淡出、格子直接填上、头边说一句；宠物身体不动，只眨眼和换表情。
- **主页**：Asleep 行不再有空心圈（入账后直接出勾）；底栏中间的 Today 图标换成三根小柱，三个名字都是次要灰。
- **Pets**：「还能遇见谁」那格只写 Still to meet，不写数量；宠物页的 Dress up 先藏起来。
- **Settings → About**：版本号、隐私政策、意见反馈。链接在 `project.yml` 的 `PrivacyPolicyURL` / `FeedbackURL`，空着时显示 Soon。
  2026-11-15 起隐私政策指向 https://claude.ai/artifact/HMXtCuG1i5mbdfY4bTJuRr （测试阶段先放这里，上架前换到自己的域名）；意见反馈还空着。

### 第 3 批：改名 Ovenpals、分享卡（2026-11-12）

- **桌面名 Ovenpals**（`project.yml` 的 `CFBundleDisplayName`）。target、scheme、目录名都还叫 HealthPet3D，用户看不到。
- **分享卡**：底部的 HealthPet 换成 Ovenpals，下面加一行让别人找得到 App：有短链接后写短链接（`project.yml` 的 `ShareLinkText`，
  比如 `ovenpals.app`），没有之前写 “iPhone app”。系统分享面板的预览名也是 Ovenpals。卡片高 446 → 456 pt。
- **9:16 竖版**：Share 页圆点下面多了 Card / 9:16 两个小按钮。9:16 导出 1080 × 1920，卡片缩到 86 % 放在正中，
  避开快拍上下的按钮区。选了哪个会记住。达成自律周时自动弹出的那张仍是卡片。
- **健康权限说明**：写入那条改成 “Ovenpals does not write to Apple Health.”。读取那条和首次打开的 Heart rate 一行先不动
  （2026-11-12 用户定：HRV / 静息心率照读，文字不改）。
- 服务器出错时的提示里的 HealthPet 也换成 Ovenpals。

### 第 4 批：Bundle ID、App Group、iCloud 备份（2026-11-12）

- **Bundle ID 换成 `com.ovenpals.app`**（`project.yml`，`bundleIdPrefix` 也改成 `com.ovenpals`；`tools/sim-shots.sh` 跟着改）。
  第一次传 TestFlight 之后就不能再改。模拟器上它算一个新 App：旧的 com.healthpet.app3d 那份数据不会带过来，可以删掉旧 App。
- **数据搬进 App Group `group.com.ovenpals.app`**（`Store/AppGroup.swift`）：宠物、入账流水、主宠、入睡目标这些都存在这里，
  以后的主屏小组件读同一份。首次打开、导览、外观、通知开关、时间格式还留在 App 自己的设置里（小组件用不到，截图脚本在启动时设置它们）。
  打包时没有 App Group 能力就退回 App 自己的设置；App 自己的设置里已有的数据会搬一次。
- **iCloud 键值备份**（2026-11-15 起不放健康数值，见下面「iCloud 里只有打卡记录」）：领养日、Memories、累计自律周、每只宠物的活动日（= 经验）、请假、入账流水（不带数字），每次保存都同时写进
  iCloud（`PetStore` / `CreditBook` 的 `mergeFromCloud` / `pushToCloud`，`AppModel.syncCloud`）。不需要登录界面；
  重装或换新 iPhone 后，iCloud 的数据一到就合并进来：只加不减，领养日取更早的那天。最近 30 天的健康快照不备份，重新从 Apple 健康读。
  键值存储一共 1 MB，入账流水最多 1,500 行，大约 300 KB。

**传 TestFlight 之前要做的（需要付费开发者账号，留给「测试版 App 制作」）**

1. 在 developer.apple.com 的 Identifiers 里注册 App ID `com.ovenpals.app`，勾选 HealthKit、iCloud（只要 Key-value storage，
   不需要 CloudKit 容器）、App Groups；再新建 App Group `group.com.ovenpals.app`，并勾到这个 App ID 上。
2. 把 `project.yml` 的 `DEVELOPMENT_TEAM` 填成团队 ID，重新 `xcodegen generate`，Xcode 自动签名会生成描述文件。
3. 在 App Store Connect 用同一个 Bundle ID 建 App，名字 Ovenpals。
4. 装上之后看一眼：Settings 能打开，重装后 Memories 和宠物等级还在（等 iCloud 下载完，通常几秒到一分钟）。
   免费的个人团队签不了 iCloud 和 App Group，所以 USB 直装也要用付费团队。

## Dress up 装扮（PRD v0.3 §5.4，2026-11-12）

设计稿：项目文件 `健康宠物/3D方案/ui-final-v3/dressup-v1/`（交接说明、单帧 D01–D13 / N01–N11）。

- **装饰引擎**：`PetWeb/src/decor.js` 原样复制自 `健康宠物/3D方案/decor-v1/workbench/src/decor.js`（第十一轮，51 件），
  不要改它的 `FLAT_Z.mode` 和 `FIT_OVERRIDES`。bridge 多了 `decor`（装饰 id 数组）：只换装扮时不重新加载宠物；
  减弱动态效果时装饰不晃不转。宠物改了形状或眼距，按交接说明 §2 重算。
- **规则**在 `Packages/PetCore/Sources/PetCore/DressUp.swift`（有测试）：每天第一次打开 +1 分（App 变成 active 时，主页不提示），
  5 分抽一次，从没有的里面均匀随机，不出重复；导览结束送生日帽（不扣分，老用户下次打开也送一次）；集齐 51 件后不再加分。
  衣柜共用，每只宠物各记各的穿法，每个位置一件；主页、宠物详情、Dress up 的宠物都穿着。
  积分不直接存数字，而是存「哪几天拿过分」和抽了几次，所以两台 iPhone 同一天打开只算一次、重装后先拿的那 1 分也不会盖掉 iCloud 里的。
- **数据**存在 App Group，并写进 iCloud 键值存储（`3d.dressUp`）：天数和装饰取并集，穿法取较新的那份。
- **页面**：宠物详情的 Dress up（够抽时有小圆点）、Pets 页顶上的 “Draw a new item”（进主宠的 Dress up）、Pets 图标的小圆点、
  `Features/DressUp/`（衣柜、积分说明、礼物卡）。读屏、大字号（3 列、舞台 200 pt、整页可滚）、减弱动态效果按交接说明 §6 做了。
- **装饰小图** `Resources/Assets.xcassets/decor_<id>`：和设计稿 `app-icons/` 同样的构图，按 8 倍重新渲染，
  礼物卡上 132 pt 的大图也清楚（@3x 396 px）。5 件平面图标（翅膀、仙子翅膀、喷气背包、杠铃、铃铛项圈）同设计稿。
- **Pets 格子和分享卡上的装扮**（`Pet/PetSnapper.swift`）：静态图里没有装扮，所以穿了装扮的宠物由 App 现拍：
  另开一个看不见的网页（360 pt，完全不透明，放在窗口最底层、被 App 自己的页面盖住；iOS 拍网页时带上它自己的透明度，所以不能把它本身调透明），按「宠物 + 装扮 + 姿势（平常 / 开心 / 骄傲）」各画一次，
  黑底拍一张、白底拍一张，两张对比算出透明背景，存进 `Caches/PetStills/`。拍好前先显示没装扮的静态图，拍好后换上；
  同一只宠物换了装扮，旧图删掉。离开 Dress up 时先把这只的三个姿势拍好；分享卡等图拍好了再出图。网页 20 秒没活就关掉。
  主页、宠物详情、Dress up 在活宠物加载完之前显示的静态图：拍过就用穿着的那张，没拍过就先用没装扮的（这时不现拍，免得和活宠物的网页抢着加载）。
  **要在真机上确认**：iOS 对被盖住的 WKWebView 不保证会画，模拟器上能拍到不代表真机也能。
  真机上看 Pets 页和分享卡：穿了装扮的宠物应该在一两秒内换成穿着的样子；如果一直是没装扮的样子，
  Xcode 控制台会有 `[pet] snapper: no picture of …` 或 `… came out empty`（拍好的是 `[pet] snapper: took …`），日志括号里有两张图的平均亮度和实心占比，可以看出是没画出来（几乎没有实心）还是黑白底没换成（全是实心）。
- **主页的对话气泡**躲开装扮：网页换装后两帧量出装扮的最高点（`outfit` 消息，和 anchors 同一个 0–100 的框），
  主页的台词、睡觉提问和入账小标签都放在宠物和装扮里更高的那个上面。
- **模拟器截图用的启动参数**（只在 Debug）：`-hp3dDressUp ready|short|last|all|gift`（预置装扮数据：7 分 23 件 / 3 分 /
  只差一件 / 全齐 / 刚走完导览的新用户）、`-hp3dRoute dress:toast`、`-hp3dDressSlot eyes`、`-hp3dDressNote points|locked`、
  `-hp3dDressGift YES`（抽一次，弹礼物盒）、`-hp3dGiftOpen YES`（礼物盒自己打开）。
  预置数据也写进 iCloud 键值存储：模拟器的 iCloud 值卸载重装也还在，不写的话启动时一合并又回到上次的衣柜。
  `tools/sim-shots.sh` 每次启动都带 `-hp3dDressUp ready`（不然新装的 App 每张主页截图都会弹欢迎礼物），第 7 组是 Dress up。

## 新表情（PRD §5.3、§10.3 第 17 项，2026-11-13）

`PetWeb/src/engine.js`、`live.js` 换成 41 个表情的版本（原样复制自 `健康宠物/3D方案/expressions-v2/src/`，
第一批 8 个 + 第二批 7 个，「动一动」用户已去掉）。bridge 新加 `Pet.react(id, {pet, hold, at})` 和 `Pet.release(id)`：
`react` 用表情自己的优先级（点一下或更新的时刻可以打断），`pet` = 只给这只宠物（页面还在换宠物时等它装好再播），
`hold` = 等一下 / 拆礼物 一直播到 `release`。Swift 这边是 `PetStage.react / endHold / beg`。

| 表情 | 在哪里触发 |
| --- | --- |
| 眼巴巴 | 主页有没点的食物泡泡时，每 14–18 秒朝最近的泡泡看一次（醒来、导览、吃东西和吃完 10 秒内、睡前提问、礼物卡时不做） |
| 好吃 | 每次吃完一个泡泡（代替以前借用的被挠痒） |
| 升级 | 宠物升级那一刻（吃泡泡时；早上揭晓隔夜升的级也用它，代替以前的欢呼 / 开心跳） |
| 大庆祝 | Lv 10 / 20；月度成就；自律周累计到 10 的倍数；Memories 里的 30 / 100 个准时夜、100 次运动（§8.4 的清单）；集齐 51 件装饰 |
| 打招呼 | 首次打开第一页；当天离开 3 小时以上再回来；在 Pets 里点开一只宠物 |
| 拜托 | 宠物问要不要开睡前提醒那一次；首次打开的健康授权页 |
| 等一下 | 首次打开读 30 天数据时（读完放开，找到、点头后才进下一页）；主页刷新超过 1 秒时（醒来时不做） |
| 放假 | 请假那天的基础状态（昨晚用了请假） |
| 呼呼 | 今天有运动或 1 万步入账后，待机小动作里大约每 3 次出现 1 次 |
| 想你了 | 隔了 3 天以上的第一次打开（代替给你打气，只说想念） |
| 点点头 | 改入睡时间（Settings）、请假、「手表记错了」保存、设为主宠（Pets 或主页名字菜单）。Settings 和 Today 上没有活宠物，宠物回到主页时点头 |
| 看月亮 | 目标入睡时间前一小时的基础状态（主页每 30 秒看一次时间） |
| 拆礼物 | Dress up 按 Draw 到点开礼物盒之间一直晃，点开后宠物的小盒子也弹开 |
| 照一照 | 衣柜里戴上一件、礼物卡上 Wear、主页欢迎礼物戴上后进宠物页（代替以前借用的骄傲挺胸） |
| 拍照 | **还没接**：分享页上只有卡片图，没有活的宠物，播了也看不到 |

- 戴着帽子时，头顶上的小特效（升级的 Lv、等一下的小珠、呼呼的汗珠）抬到帽子上面（bridge 量帽子的最高点，改 `anchors.crown`）。
- 首次打开的三页换成活的 Toast（第二页健康授权页新加了一只，最大 150 pt，页面放不下时先缩它，下面的小字不会被截断）。全屏盖住主页的页面放开宠物后，主页的 `LivePet` 自己再把宠物拿回来。
- 自己定的数字（用户没确认）：打招呼要离开 3 小时；自律周累计 10、20、30… 周放大庆祝；眼巴巴间隔 14–18 秒；刷新超过 1 秒才等一下。

## 音效和触感（PRD v0.3 §8.4、§10.3 第 18 项，2026-11-13）

声音是 `健康宠物/3D方案/sfx-v1/` 的「玩具厨房」v3（用户 11-13 定稿）：`wav/` 里的 36 个文件原样放进 `Resources/Sounds/`
（「切页轻响」ui_tick 设计里默认不用，没放）。触感里有节奏的 6 个（升级、自律周、大庆祝、喜欢你、挠痒、摸摸）是
`Resources/Haptics/*.ahap`，按 spec.json 的 marks 写的；其余单下的用 UIKit 的 feedback generator。

- 播放：`Sound/Sounds.swift`，AVAudioEngine，启动时在后台读进内存；音频会话 `.ambient`，跟着静音开关走，和音乐、播客混在一起，
  不打断也不压低。同时最多 2 个声音，第 3 个丢掉最轻的（L1 < L2 < L3，一样重时新的留下）；同一个声音 0.12 s 内不重复；App 不在前台不出声。
- Settings 在 Look 下面新加 **Sounds & Haptics**：Sound effects、Haptics 两个开关，默认开，各管各的，存在本机（`3d.soundEffects`、`3d.haptics`）。
  原来的 3 处 `.sensoryFeedback`（主页咽下、Dress up 换装、拆开礼物）也跟着 Haptics 开关。
- 收获（`HomeScreen.harvest`）：0 s 啵、0.76 s 小粒进嘴、1.72 s 小点落进格子时放格子音（运动格 1–3 = C6 D6 E6，准时夜和请假格 1–5 =
  G6 A6 C7 D7 E7；已经亮着的格子只闪一下，低 6 dB；没准时的月亮和 Whoop 负荷 = 夹进账本）。减弱动态效果时只有啵 + 0.3 s 后的格子音，两下触感。
- 宠物的表情：bridge 在表情真正开始时发 `expr`（`asked` = App 要的时刻）。只有 App 要的时刻出声（`Cues.byExpression`，偏移按设计的「对齐」一栏）：
  打招呼、拜托、点点头、给你打气、醒来（3.05 s 认出你时再一声打招呼）、骄傲挺胸、开心跳、升级、星星眼（新宠物）、打卡欢呼（自律周）、
  大庆祝、喜欢你、想你了、照一照（转身两次）。待机里导演自己挑的、点宠物出来的表情都不出声；新表情开始时，上一个表情还没播的声音取消。
  首次打开读完 30 天，等一下找到时那一下点头放点头声（bridge 按等一下自己的时间算，发 `expr` 'found'）。
- 摸宠物：只有触感（用户 11-13 暂停了互动叫声）：戳一下 soft、第 3 下连点挠痒四下 light、按住摸摸时连续轻震（跟着蹭的节奏，松手停）；
  连点到晕乎乎、熟睡时被点醒都不震。bridge 的 `tap` 和 `hold` 消息带 `touch`，松手发 `holdEnd`。
- Dress up：戴上按位置放一个八音盒音（头顶到背后越来越低）、脱下、分不够时点 Draw 的「噗」；礼物卡：盒子落下、每次晃一下珠子响一次、拆开。
- 分享：分享页（和自律周弹出的卡）第一张图出来时、按 Share 时，玩具相机「咔嚓」。
- 首次打开「你已经遇见了谁」那一页：新宠物的闪光声。
- 自己定的（用户没确认）：礼物盒的珠子声跟着礼物卡上盒子的晃动（每 2.2 s 一次），不是设计里 1.6 s 的不停循环（卡片上盒子的晃动是 2.2 s 一次，对不上）；
  分享页只在第一张图出来时咔嚓一次，左右滑不响；拍照表情还没接（分享卡上没有活宠物），声音先单独放。
- 模拟器上没有触感，声音可以听；触感要真机（TestFlight）上确认。

## 首页的数据

- 食物气泡：每次 ≥ 20 分钟的运动（最多两个，图标是运动类型）、≥ 1 万步、昨晚的入睡、有 Whoop 时的当天 strain。点一下入账；
  Settings → Test build →「Grow the food back」可以把今天吃过的还回来（Live 数据下已经加上的宠物经验不退）。
- 状态区：入睡时间（Apple 健康里这一晚主睡眠前第一段不是小睡的睡眠开始，或 Whoop 的主睡眠开始）；Apple Watch 用户是昨晚睡眠时长，Whoop 用户是 Whoop 恢复分。都是原值，App 不估算。
- 规则在 `Packages/PetCore` 里，有单元测试（Linux 上也能跑：`cd Packages/PetCore && swift test`）。

## iCloud 里只有打卡记录（PRD v0.3 §10.3 第 19 项，2026-11-15）

App Review 5.1.3 (ii) 不允许把健康信息存进 iCloud，所以 iCloud 键值存储只放 App 自己的打卡记录，健康数值都留在手机上：

| 键 | iCloud 里有什么 | 只在手机上 |
|---|---|---|
| `adoptedOn` | 领养第一只宠物的那天 | |
| `memories` | 里程碑标题（第一个 2 万步日、准时夜连胜、在一起 N 天） | |
| `disciplinedWeeks` | 哪几周是自律周 | |
| `activityLog` | 哪天算了哪个活动（= 宠物经验） | |
| `leaveDays` | 请假的晚上 | |
| `3d.credits` / `3d.creditsSince` | 入账流水：哪天、哪种食物、喂了哪只、升没升级、什么时候收的、是不是自动收下；运动只留名字（"Run"） | 分钟、步数、入睡时间、strain（"Run 32 min"、"10,240 steps"、"Asleep 22:48"、"Strain 11.4"） |
| `3d.dressUp` | 装扮的积分日、抽到的装饰、穿法 | |
| — | | 「手表记错了」改过的入睡时间（`sleepFixes`，以前的版本放进过 iCloud，现在启动时会删掉）、最近 30 天的健康快照 |

- 流水在 iCloud 里的样子：`CreditRecord.bare`（PetCore，有单元测试）。运动的 id 去掉分钟，同一天同名运动按顺序编号（`…/workout:Run#1`）。
  每次保存和启动时都用这个样子覆盖 iCloud，所以以前写进去的带数字的版本也会被换掉。
- 重装或换新手机：从 iCloud 回来的流水先只显示名字（"Run"、"10k-step day"、"Night's sleep"、"Whoop strain"）；
  App 重新读到那几天的数据后（最近 30 天）会把数字和原来的 id 补回去（`CreditBook.refill`），这些食物不会再长一遍。更早的日子就一直只显示名字。
- 合并时手机上完整的一行永远不会被 iCloud 里不带数字的那行替换。

**给 App Review 的说明（提交审核时粘到 Notes 里）：**

> Ovenpals uses iCloud key-value storage only to back up the app's own progress so it survives a reinstall or a new iPhone: the day the first pet was adopted, milestone titles, which weeks were completed, which days counted for which activity, leave days, the ledger of collected check-ins (kind, day, pet, workout type, level change) and pet outfits. It stores no HealthKit or WHOOP values: no step counts, durations, sleep times, heart rate, HRV, recovery or strain. Those stay on the device and are re-read from Apple Health or WHOOP.

## 能量棒：Whoop 红灯天好好休息（PRD v0.3 §5.1，2026-11-14）

- 规则：Whoop 恢复分 < 34%（红灯）且当天 strain ≤ 10，这一天算一次（`Activity.redDayRest`，取代原来的「连续两天匹配恢复」）。
  和蜂蜜罐一样，当天结束后才算（strain 白天还在涨）；Whoop 还在校准、没有恢复分的日子不算红灯天。
- 红灯天休息时 strain 通常 < 10，所以同一天也会算蜂蜜罐的「匹配的一天」，两只都不变。
- 当天是红灯、strain 到目前为止 ≤ 10 时，首页宠物的底色是「放假」（和请假日一样），strain 超过 10 就回到平常；睡前一小时还是「看月亮」优先。
- 「还能遇见谁」里能量棒的提示：Whoop: take it easy on a red day (strain 10 or less)。图标是沙发。

## 用真实 Whoop 数据测试（2026-11-13）

Whoop 的数据不经过手机：App 匿名登录 Supabase → `whoop-connect` 给出 Whoop 登录网址 → 用户在弹出的网页里登录、允许 →
Whoop 跳回 `whoop-callback`（存好加密的 token，补拉 30 天）→ 网页跳回 `ovenpals://whoop/connected` → App 用 `snapshots` 读数据。
所以**模拟器也能连真实 Whoop**，不用等 TestFlight。

一次性准备：

1. developer-dashboard.whoop.com 用自己的 Whoop 账号登录，建 Team，再建 App：
   - Redirect URL：`https://fakurcgffasfrdupnubt.supabase.co/functions/v1/whoop-callback`
   - Scopes：read:recovery、read:sleep、read:cycles、read:profile（列表里有 offline 也勾上）
   - Webhook URL（可以以后再填）：`https://fakurcgffasfrdupnubt.supabase.co/functions/v1/whoop-webhook`，版本选 v2
   - 没审核的 App 最多 10 个 Whoop 会员能连，自己测试够用。
2. 把 Client ID / Client Secret 填进 `backend/supabase/.env.whoop`（不进 git），然后在 `backend/` 里：
   `~/Developer/tools/supabase secrets set --env-file supabase/.env.whoop --project-ref fakurcgffasfrdupnubt`，
   再 `~/Developer/tools/supabase functions deploy --project-ref fakurcgffasfrdupnubt`（5 个函数一起部署）。
3. `Config/Secrets.xcconfig`（照 `Config/Secrets.example.xcconfig` 复制，不进 git）里要有项目 ref `fakurcgffasfrdupnubt` 和 anon key（Supabase → Project Settings → API Keys，或 `supabase projects api-keys`），否则 Settings 里 Whoop 显示「Not in this build」。改完要 `xcodegen generate`。

测试：⌘R 运行 → 「…」→ Settings → Test build → Data 选 **Real data** → 往上翻到 Whoop →「Connect Whoop」→ 登录、允许 → 回到 App 显示 Connected。

- 模拟器里没有 Apple 健康数据，所以只看得到 Whoop 的部分：入睡 / 醒来时间、Whoop 恢复条、strain 气泡、准时夜，
  和 Whoop 专属的三只（蜂蜜罐、热牛奶、能量棒）。运动和步数走 Apple 健康，要真机。
- Whoop 刚开始戴的前几天还在校准，恢复分不给，恢复条会空着。
- 数据超过 30 分钟没更新时，打开 App 会让服务器重新拉最近 3 天；Settings → Test build →「Refresh now」也可以。
- 报错「The Ovenpals server answered with an error (500)」多半是 Supabase 里的 Whoop 密钥没设好。

## 数据测试（2026-11-25）

PetCore 里有两组按 PRD v0.3 写的数据测试，Linux 上也能跑（`cd Packages/PetCore && swift test`）：

- `PRDv03BoundaryTests`：每条打卡规则的边界，差一分钟、一步、一个百分点各试一次（20 分钟、1 万步、目标 + 30 分钟、
  18:00 分界、周一到周日、04:00 自动入账、L×(L+1)/2、自律周翻倍、蜂蜜罐 / 热牛奶 / 能量棒）。
- `DataScenarioTests`：照 Apple 健康和 Whoop 真实送来的样子造的整周数据（睡眠分段、两个睡眠 App 叠在一起、
  Whoop 和 Apple Watch 同时戴、夏令时、坐飞机换时区），从原始数据一路算到本周格子、泡泡、宠物经验和 Toast 等级。
  `DataTestKit.swift` 里的 `AppRun` 按 `AppModel.evaluate` 的顺序算，改那边时这边要跟着改。

- `CalendarDayTests`：换时区之后存下的日子还是原来那天（12 个时区两两互飞，夏令时那几天也试）。

测出来的两个问题同日已修：

- **换时区**：打卡记录、自律周、请假、「手表记错了」和入账编号都按「某天 0 点那一刻」存，飞到别的时区后同一天会被当成新的一天
  （经验重复、Memories 重复「Collected for you」、旧自律周的翻倍对不上、等级可能下降）。现在每次计算前 `PetStore.adopt` /
  `CreditBook.adopt` 把存下的日子换回它的日期（PetCore `CalendarDay`），iCloud 拿回来的也一样。适用于 UTC−10:59 到 UTC+13 之间存的日子
  （夏威夷到新西兰夏令时）；现在所在时区存的日子任何时区都不变。航班前后靠近午夜的运动可能落到相邻的一天，这是按当地日期算的本来结果。
- **正念不算运动**：Mind & Body、太极再长也只喂抹茶，不占本周运动格（`DisciplineTracker.countsAsWorkout`）；Today 卡片和日历小卡显示
  能算数的那次运动。

以后再发现还没修的问题，测试用 `knownIssue` 包着：问题还在时这条测试显示 skipped（原因写在里面），修好后它会失败、提醒把包装拿掉。

用真实数据核对：`Packages/HealthReplay` 把「健康」App 导出的数据按同一套规则逐天回放，列出每周结果、宠物等级和数据里
容易让 App 看起来算错的地方（用法见那里的 README）。

用一份带 WHOOP 的真实导出回放后又改了三处（2026-11-25）：

- **运动按显示的整分钟算**（`WorkoutSession.shownMinutes`）：WHOOP 写进「健康」的运动都比整分钟少 1 秒，20 分钟的会变成
  19 分 59 秒。现在 19 分 30 秒以上显示「20 min」，也就算一次运动。
- **步数只取记得最多的一个来源**（`HealthKitProvider.dailySteps`）：WHOOP 每天写一条从入睡到下次入睡的全天步数，「健康」
  按来源顺序合计时可能把它叠在 iPhone 的步数上，同一段路算两遍。App 显示的步数因此可能比「健康」里的少。
- **分段的运动合成一次**（PetCore `WorkoutJoiner`）：同一个 App、同一种运动、每段在上一段结束后 10 分钟内开始，就合成一次，
  分钟数相加，算在第一段开始的那天。WHOOP 会在力量训练组间心率掉下来时把一次训练断成几段。泡泡的编号用合起来后第一次够
  20 分钟时的分钟数，后面的段再同步进来也不会多长一个泡泡。不同 App 的不相加（两个 App 记同一次跑步时间是重叠的）。

App 优先照顾 WHOOP 用户。之后又按这个原则改了两处（2026-11-25）：

- **几个 App 记的同一次运动只算一次**（PetCore `WorkoutJoiner.workouts`）：WHOOP 和 Apple Watch、Strava 都把同一次运动
  写进「健康」时，时间重叠一半以上、来自不同 App 的算同一次，只长一个泡泡、记一行账。留下哪条：先留够 20 分钟算运动的
  （另一个 App 晚开了几分钟也不吃亏），再留有具体运动名的（WHOOP 没标运动时写的是 Workout），再留 WHOOP 的（和 WHOOP App
  里看到的分钟数一样），最后留最长的；WHOOP 没写距离就用别的 App 的。同一个 App 自己的两条不会被当成一条。先到的那条
  泡泡已经吃了，后到的那条被留下时也不会再长一个（`Credit.aliases`）。
- **入睡前的小睡不算入睡时间**（PetCore `SleepNights`）：PRD v0.3 写的是「18:00 以后第一段睡眠的开始」，WHOOP 会自动记小睡，
  19:10 睡 25 分钟、凌晨 2 点才睡的一晚原本会被判准时。现在间隔不到 2 小时的片段算同一觉，睡得最久的那一觉是这一晚的
  主睡眠，它之前睡着不到 90 分钟的那一觉是小睡，不算入睡时间（时长照算）。半夜醒来一个多小时、或者先睡了 90 分钟以上
  再醒很久，入睡还是第一次睡着的时间。接了 Whoop 的用户，入睡时间本来就用 Whoop 自己的主睡眠（服务器去掉了小睡），两边一致。

## 主页底栏：三个一样大的圆（2026-11-26）

- Pets · Today · Memories 还是圆按钮，但三个一样大（72 pt），名字从圆下面的小灰字搬进圆里：图标在上、名字在下，
  11 pt 深色。Today 只靠颜色突出（白天深绿底青柠，夜里青柠底深色），不再比另外两个大。
- 圆跟着系统字号长（主页最多放大两档，到时约 89 pt），最长的 Memories 也放得进圆里。
- Pets 的小绿点在圆的右上方；收获时飞到 Memories 的小点、导览第 3 步的高亮框都按新位置算，不用另改。
- 对比图在项目文件 design/dock-equal-circles.png（C 方案）。

## 还没做

- 真机上确认 Pets 格子和分享卡的装扮图拍得出来（见 Dress up 一节）；真机上听一遍声音、试一遍触感（见音效一节）。
- 拍照表情：分享卡是静态图，要让卡上的宠物在预览时动起来才接得上。
- 分享卡的 Milestone 卡、数据详情页。
