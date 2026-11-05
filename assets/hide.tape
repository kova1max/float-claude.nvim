# Hide the popup while Claude answers, then come back. Run with assets/record.sh.
Output assets/hide.gif

Set Shell "bash"
Set FontFamily "JetBrains Mono, Menlo"
Set FontSize 16
Set Width 1100
Set Height 560
Set Padding 16
Set Theme "TokyoNight"
Set WindowBar Colorful
Set Framerate 24
Set TypingSpeed 45ms

Hide
Type "nvim -u assets/demo/init.lua assets/demo/cart.lua" Enter
Sleep 1.5s
Type "26Gzb"
Sleep 300ms
Show

Sleep 500ms
Type "21GV24G"
Sleep 400ms
Type " ai"
Sleep 400ms
Type "explain total"
Sleep 300ms
Enter
Sleep 800ms
Ctrl+Q
Sleep 400ms
Type@200ms "kkkkk"
# The statusline shows a dot once the reply is in.
Wait+Screen /●/
Sleep 1.2s
Type " ai"
Sleep 2.5s
