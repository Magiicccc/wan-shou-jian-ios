# 万兽共鸣 · iPhone

原生 SwiftUI 居家音乐灯光工具。麦克风实时分析外放音乐，统一灯光状态驱动宝宝剑与沉浸视觉；包含后台音频、BLE 状态恢复、有界重连和手动试灯。默认界面为律动、设备和设置。

## 使用

1. 通过 GitHub Actions 构建并下载 `WanShouJian-unsigned-ipa` artifact，解压得到通用安装包 `WanShouJian-unsigned.ipa`。
2. 在本机通过 `scripts/configure-ipa.py` 将自己的设备摘要写入新的安装包，步骤见「本机设备配置」。
3. 使用 Sideloadly 为本机配置后的安装包签名并安装。
4. 将宝宝剑设为配对状态，让其他控制工具释放它。
5. 打开 App，在设备页扫描并选择自己的设备；设备确认完成后，可通过「手动试灯」观察红、绿、蓝、低亮和高亮。
6. 回到律动页点「唤醒万兽」，授权麦克风并完成两秒校准，随后根据外放音乐自动呼吸和渐变。长按白狐或使用「停止律动」结束会话。

后台律动默认开启，已启动的音乐会话在切换 App 和锁屏时继续采音与提交 BLE 灯效；UI 动画在后台暂停。关闭后台开关时释放采音、回到前台后恢复既有会话。主动停止清除重连意图与音频资源。系统音频服务完全重置后，由用户再次点击开启。

设备确认响应的长度检查与实物亮灯观察分别记录。锁屏、来电、音乐 App 路由兼容性和 30 / 60 分钟运行需要真机专项验证。首次物理操作以温和亮度开始，界面中的 RGB 提交状态表示本机已发送，实际颜色以剑身观察为准。

## 构建

Windows 编写代码，GitHub Actions 的 macOS 运行器执行 Xcode 编译与模拟器测试。代码签名留给用户电脑上的 Sideloadly。

```sh
brew install xcodegen
bash scripts/run-tests.sh
bash scripts/build-unsigned-ipa.sh
```

部署目标 iOS 17，Bundle ID 为 `com.magiicccc.wanshoujian`。CI 打印实际 Xcode 与 Swift 版本，测试成功后打包设备 IPA，同时上传模拟器截图、测试结果与 SHA-256。源码中的原创建模图标由 `scripts/make-icon.swift` 绘制。

公开配置中的 `LIGHTSTICK_MAC_SHA256` 默认为空。默认 GitHub Actions 构建通用 IPA，预览与编译测试可直接执行，真机控色在本机设备配置完成后启用。云端工作流采用统一构建，无需配置设备相关 GitHub Secret。

`--preview` 启动参数供模拟器界面测试使用：可显式开启合成信号试听，麦克风与实体蓝牙保持隔离。

## 视觉资源

公开构建展示中性音乐光环。本人私有图层在本机打包阶段载入，资源路径为 `PrivateVisuals/fox-open.png` 与 `PrivateVisuals/fox-closed.png`。图像主体交叉淡化、眼部发光、细环脉冲和高潮光冠分别绘制；整个头部保持固定大小。视觉颜色采用最近提交的 RGB，音频特征控制眼神与光环层次。

若本机已有适用的两张 PNG，可在个人配置步骤增加 `--visual-assets <目录>`。脚本校验 PNG 签名、IHDR、尺寸和资源重名，随后将文件注入新的无签名 IPA；云端通用构建保持可独立复现。

## 本机设备配置

设备摘要为规范化地址的 SHA-256：地址采用大写、冒号分隔的六字节格式，以 UTF-8 编码后计算，结果为 64 位十六进制字符。App 通过 `KnownDeviceMACSHA256` 管理已核对设备的兼容性范围；设备签名真实性验证属于独立的后续工作。

在 Windows PowerShell 中，将自己的摘要放入当前终端环境变量，再配置安装包。输出选择仓库外的本机目录：

```powershell
$env:LIGHTSTICK_MAC_SHA256 = '<64位十六进制设备摘要>'
New-Item -ItemType Directory -Force '../local-builds' | Out-Null
python scripts/configure-ipa.py --input 'WanShouJian-unsigned.ipa' --output '../local-builds/WanShouJian-personal.ipa'
Remove-Item Env:LIGHTSTICK_MAC_SHA256
```

脚本也支持 `--mac-sha256` 参数。输入采用通用无签名 IPA，输出采用新的文件名；配置后的 IPA 交给 Sideloadly 签名。脚本会校验摘要格式，并保留原通用包。

macOS 本机编译也可通过可选环境变量注入相同的 Xcode 构建设置：

```sh
export LIGHTSTICK_MAC_SHA256='<64位十六进制设备摘要>'
bash scripts/build-unsigned-ipa.sh
unset LIGHTSTICK_MAC_SHA256
```

设备摘要作为稳定的兼容性标识写入定制 IPA 的 `Info.plist`，获得该安装包即可读取。原始地址、个人设备配置与定制安装包保留在本机；公开源码、通用云端产物和合成测试向量共同构成可复现的共享版本。

## 源码范围

公开内容为原创界面、协议编码器、测试与构建配置。官方图片、个人实测日志和认证材料保留在本地。协议实现来自自有设备接口观察，XCTest 使用合成测试向量。运行时读取的设备地址仅显示在本机界面。

参考：[CoreBluetooth](https://developer.apple.com/documentation/corebluetooth)、[Sideloadly](https://sideloadly.io/)。
