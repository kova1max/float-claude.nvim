# Ask for a change; the selection is rewritten in place. Run with assets/record.sh.
Output assets/edit.gif

Set Shell "bash"
Set FontFamily "JetBrains Mono, Menlo"
Set FontSize 16
Set Width 1100
Set Height 440
Set Padding 16
Set Theme "TokyoNight"
Set WindowBar Colorful
Set Framerate 24
Set TypingSpeed 45ms

Hide
Type "nvim -u assets/demo/init.lua assets/demo/two_sum.lua" Enter
Sleep 1.5s
Show

Sleep 600ms
Type "5GV13G"
Sleep 400ms
Type " ai"
Sleep 500ms
Type "use a table of seen numbers, one pass"
Sleep 300ms
Enter
Wait+Screen /u to undo/
Sleep 2.5s
