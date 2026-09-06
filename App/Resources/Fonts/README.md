# WSJ Display ExtraLight

这是用于万兽共鸣标题的本地字体子集。字形源于 Noto Serif CJK SC ExtraLight 2.003；项目调整字体名称并保留当前 App Swift 源码中的字符及可打印 ASCII。字体名称为 `WSJ Display`，PostScript 名为 `WSJDisplay-ExtraLight`。

## 来源与许可

- 上游仓库：<https://github.com/notofonts/noto-cjk/tree/Serif2.003/Serif>，固定标签 `Serif2.003`。
- 原字体：`Serif/OTF/SimplifiedChinese/NotoSerifCJKsc-ExtraLight.otf`。
- 原字体版权声明保留在字体元数据和 `COPYRIGHT.txt`。
- `OFL.txt` 保存上游 SIL Open Font License 1.1 的完整原文，按原始字节复制。
- 此修改字体及字体专用衍生脚本采用 OFL-1.1；App 其余代码的许可单独适用。
- OpenType 的系列名、全名、PostScript 名和 CFF/FD 名称均改为 WSJ 名称；原作者与上游名称保留在来源说明和版权信息中。

## 复现

在 iOS 项目目录运行：

```sh
python -m pip install fonttools==4.60.0
python scripts/subset_display_font.py
```

脚本会下载固定版本原字体与许可，并在转换前验证 SHA256。也可通过 `--source-font` 和 `--source-license` 指定已有下载文件。输入范围为 `App/**/*.swift` 的实际字符、Swift Unicode 标量转义及 U+0020 至 U+007E；控制字符由字体排版系统处理。新增界面用字后重新运行即可更新子集。

`subset-manifest.json` 记录来源校验值、字形数量和产物校验值；`codepoints.txt` 列出纳入的码点。iOS 加载与关键中文字符覆盖由 `DisplayFontTests.swift` 检查。
