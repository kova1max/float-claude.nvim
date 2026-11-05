# Ask about the selection; the answer streams in. Run with assets/record.sh.
Output assets/answer.gif

Set Shell "bash"
Set FontFamily "JetBrains Mono, Menlo"
Set FontSize 16
Set Width 1100
Set Height 480
Set Padding 16
Set Theme "TokyoNight"
Set WindowBar Colorful
Set Framerate 24
Set TypingSpeed 45ms

Hide
Type "nvim -u assets/demo/init.lua assets/demo/two_sum.lua" Enter
Sleep 1.5s
Show

Sleep 400ms
Type "5GV13G"
Sleep 400ms
Type " ai"
Sleep 500ms
Type "what's the time complexity?"
Sleep 300ms
Enter
Sleep 500ms
# Back in Insert mode once the answer is in.
Wait+Screen /-- INSERT --/
Sleep 1.6s
