# sux-mac

A powerful [sux-like](https://github.com/no5ix/sux) productivity tool on Mac.  
一个 Mac 端的类似 [sux](https://github.com/no5ix/sux) 的强大效率工具.


# features

<!-- - Directly Click to interact with the window under your mouse pointer (now, you don't need to click the other window first to 'activate' it, before You can interact with it. Just like the click logic on Windows!) -->
- Trackpad gestures:  
    - double tap with 2 fingers: middle click
    - clockwise rotation: close current window 
    - counter-clockwise rotation: quit current App
- Clipboard history supports both text and images. You can select a single item for copying, and it also allows you to copy all the contents in the clipboard history at once. 
    - ![alt text](/img/image-1.png)
- Automatically switch input method:
    - Every time you switch software, it will automatically prompt the current input method status.
        - ![alt text](/img/image-2.png)
    - Remember the input method used by each software last time, and automatically switch the input method according to the software. For example, after you switch from Chinese to English input method in software A, then go to B to use Chinese input method. When you go to software A, it will automatically switch to English input method. 
- Automatically maximize the window. After setting the software list, it will automatically maximize the window when these software are opened.
- Implement text input enhancement, you can use the Capslock key with the following auxiliary keys to achieve most of the text operation requirements, no longer need to switch back and forth between the mouse and keyboard, can be similar to vim, various cursor movements are very convenient
    - You can fully customize
    - default settings: 
        - Capslock + J: down
        - Capslock + K: up
        - Capslock + H: left
        - Capslock + L: right
        - ...
- Detect corners and edges and use Hammerspoon to set custom actions, and dual monitors are also supported.
    - You can fully customize
    - default HotEdges settings:
        - Quickly touch the top  **left**  half edge of the screen twice to maximize the window
        - Quickly touch the top of the screen twice  **right**  half the edge, you can slide to the top of the window
        - Quickly touch the bottom of the screen twice  **right**  half the edge, you can slide to the bottom of the window
        - Quickly touch the **left** edge of the screen twice with the mouse, you can turn the window into half the size of the screen and paste it on the **left** edge of the screen
        - Quickly touch the  **right**  edge of the screen twice to turn the window into half the size of the screen and stick it to the  **right**  edge of the screen
        - When you have two monitors, right-click on the top **left** half edge of the screen to move the window to the **left** side of the monitor and maximize it
        - When you have two monitors, right-click on the top  **right**  half edge of the screen to move the window to the monitor on the  **right**  side and maximize it
        - ...
    - default HotCorners settings:
        - Mouse touch upper **left** corner: previous page (such as the previous tab of the webpage, the previous tab of vscode)
        - Mouse the upper **right** corner: next page (e.g. the next tab of the web page, the next tab of vscode)
        - Mouse touch in the lower **left** corner: Switch to the previous software
        - Mouse the upper **right** corner: next page (e.g. the next tab of the web page, the next tab of vscode)
        - ...


# Usage

1.	Install the Hammerspoon software: https://www.hammerspoon.org
2.	Place the `.hammerspoon` folder in your user home directory.
3.	Launch Hammerspoon and reload the configuration:
    - ![alt text](/img/image-3.png)


# 功能

<!-- - 直接点击与鼠标指针下方的窗口进行交互（现在，在你能够与之交互之前，无需先点击其他窗口来“激活”它）。  -->
- 触控板手势:  
    - 用2个手指双击：中键单击
    - 顺时针旋转：关闭当前窗口
    - 逆时针旋转：退出当前应用
- 剪切板历史, 支持文字也支持图片, 可以单选某一条复制也支持一次性复制剪切板历史里的所有内容
    - ![alt text](/img/image-1.png)
- 自动切换输入法: 
    - 每次切换软件都会自动提示当前所用的输入法状态
        - ![alt text](/img/image-2.png)
    - 记忆每个软件上一次使用的输入法, 根据软件自动切换输入法, 比如你在A软件里切换为了从中文切到英文输入法之后, 然后转到B使用中文输入法, 当你转到A软件里会自动切为英文输入法
- 自动最大化窗口, 设置好软件列表之后, 当这些软件被打开的时候会自动最大化窗口
- 实现文本输入增强, 你可以通过 Capslock 键配合以下辅助按键实现大部分文本操作需求，不再需要在鼠标和键盘间来回切换, 可以类似vim一样的, 各种光标移动都十分方便
    - 你可以完全自定义
    - 默认配置: 
        - Capslock + J: down
        - Capslock + K: up
        - Capslock + H: left
        - Capslock + L: right
        - ...
- 检测角落和边缘并使用HammerSpoon设置自定义操作，还支持双显示器.
    - 你可以完全自定义
    - 默认 HotEdges 配置:
        - 快速两次鼠标碰一下屏幕顶端**左**半部分边缘, 就可以最大化窗口
        - 快速两次鼠标碰一下屏幕顶端**右**半部分边缘, 就可以滑到窗口的最顶端
        - 快速两次鼠标碰一下屏幕底端**右**半部分边缘, 就可以滑到窗口的最底端
        - 快速两次鼠标碰一下屏幕**左**端边缘, 就可以把窗口变成屏幕一半大小并且贴到屏幕**左**边
        - 快速两次鼠标碰一下屏幕**右**端边缘, 就可以把窗口变成屏幕一半大小并且贴到屏幕**右**边
        - 当你有两个显示器的时候, 右键点击屏幕顶端**左**半部分边缘, 就可以把窗口移动到**左**边的显示器并最大化
        - 当你有两个显示器的时候, 右键点击屏幕顶端**右**半部分边缘, 就可以把窗口移动到**右**边的显示器并最大化
        - ...
    - 默认 HotCorners 配置:
        - 鼠标触碰左上角: 上一个页面(比如网页的上一个tab, vscode的上一个tab)
        - 鼠标触碰右上角: 下一个页面(比如网页的下一个tab, vscode的下一个tab)
        - 鼠标触碰左下角: 切换到上一个软件
        - 鼠标触碰右上角: 下一个页面(比如网页的下一个tab, vscode的下一个tab)
        - ...



# 用法

1. 安装 hammerspoon 软件, https://www.hammerspoon.org
2. 把 `.hammerspoon` 放到你的用户根目录
3. 启动 hammerspoon, 重载
    - ![alt text](/img/image-3.png)