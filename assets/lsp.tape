# Names in an answer jump to their definitions (K: hover). Run with assets/record.sh.
Output assets/lsp.gif

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
# lua-language-server starts and reads the directory.
Sleep 4s
Type "26Gzb"
Sleep 300ms
Show

Sleep 500ms
Type "21GV24G"
Sleep 400ms
Type " ai"
Sleep 400ms
Type "how is total computed?"
Sleep 300ms
Enter
Sleep 500ms
# Back in Insert mode once the answer is in; then its names are looked up.
Wait+Screen /-- INSERT --/
Sleep 500ms
Escape
Sleep 300ms
Ctrl+W
Type "w"
Sleep 300ms
Type "/apply" Enter
Sleep 500ms
Type "K"
Sleep 1.2s
Enter
Sleep 1.4s
