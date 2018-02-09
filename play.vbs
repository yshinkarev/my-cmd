Set oVoice = CreateObject("SAPI.SpVoice")
set oSpFileStream = CreateObject("SAPI.SpFileStream")
oSpFileStream.Open "c:\Windows\Media\Alarm03.wav"
oVoice.SpeakStream oSpFileStream
oSpFileStream.Close