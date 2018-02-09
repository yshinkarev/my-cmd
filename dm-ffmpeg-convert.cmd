@rem http://forum.ru-board.com/topic.cgi?forum=5&topic=34350&start=960#17
@rem http://downloadmaster.ru/forum/viewtopic.php?f=5&t=29157&p=81303&hilit=ffmpeg#p81303

ffmpeg -i %1_a.mp4 -i %1.mp4.DMF -c:a copy -c:v copy %1.mp4