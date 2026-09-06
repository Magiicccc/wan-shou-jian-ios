# 万兽共鸣 · iPhone

原生 SwiftUI 手动灯光工具。当前版本用于一把已核对设备的前台连接、固定颜色、亮度和熄灯测试。音乐律动、后台音频和狐狸沉浸视觉进入后续阶段。

## 使用

1. 通过 GitHub Actions 构建并下载 `WanShouJian-unsigned-ipa` artifact，解压得到通用安装包 `WanShouJian-unsigned.ipa`。
2. 在本机通过 `scripts/configure-ipa.py` 将自己的设备摘要写入新的安装包，步骤见「本机设备配置」。
3. 使用 Sideloadly 为本机配置后的安装包签名并安装。
4. 将宝宝剑设为配对状态，让其他控制工具释放它。
5. 打开 App，扫描并选择自己的设备；设备确认完成后点「试灯」。
6. 分别观察红、绿、蓝、低亮和高亮。调节颜色与亮度会提交最新值；「熄灯」发送零亮度。

应用在前台保持连接，进入后台释放连接。设备确认响应的长度检查与实物亮灯观察分别记录。首次物理操作以温和亮度开始，界面中的 RGB 提交状态表示本机已发送，实际颜色以剑身观察为准。

## 构建

Windows 编写代码，GitHub Actions 的 macOS 运行器执行 Xcode 编译与模拟器测试。代码签名留给用户电脑上的 Sideloadly。

```sh
brew install xcodegen
bash scripts/run-tests.sh
bash scripts/build-unsigned-ipa.sh
```

部署目标 iOS 17，Bundle ID 为 `com.magiicccc.wanshoujian`。CI 打印实际 Xcode 与 Swift 版本，测试成功后打包设备 IPA，同时上传模拟器截图、测试结果与 SHA-256。源码中的原创建模图标由 `scripts/make-icon.swift` 绘制。

公开配置中的 `LIGHTSTICK_MAC_SHA256` 默认为空。默认 GitHub Actions 构建通用 IPA，预览与编译测试可直接执行，真机控色在本机设备配置完成后启用。云端工作流采用统一构建，无需配置设备相关 GitHub Secret。

`--preview` 启动参数供模拟器界面测试使用：颜色和亮度在屏幕预览，真实蓝牙操作保持禁用。

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
