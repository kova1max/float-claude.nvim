# With review_edits, an edit shows as a diff until accepted. Run with assets/record.sh.
Output assets/review.gif

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
Type "round the total to cents"
Sleep 300ms
Enter
Wait+Screen /nn discard/
Sleep 1.2s
Escape
Sleep 300ms
Type " yy"
Wait+Screen /u to undo/
Sleep 2s
