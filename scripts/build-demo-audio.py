"""Synthesize an original 48-second instrumental for the built-in stage demo."""
import math
import struct
import wave
from pathlib import Path

target=Path(__file__).resolve().parents[1]/'App/Resources/NightVoyage.wav'
rate=22050
chords=[(146.83,174.61,220),(130.81,164.81,196),(116.54,146.83,174.61),(130.81,164.81,196),
        (174.61,220,261.63),(146.83,174.61,220),(130.81,164.81,196),(174.61,220,261.63)]
with wave.open(str(target),'wb') as w:
    w.setnchannels(1);w.setsampwidth(2);w.setframerate(rate)
    for second in range(48):
        block=[]
        for i in range(rate):
            t=second+i/rate;section=int(t/6);chord=chords[section]
            beat=t%0.6;envelope=min(1,t/2,(48-t)/3)
            pad=sum(math.sin(math.tau*f*t)+.15*math.sin(math.tau*f*2*t) for f in chord)*.055
            pulse=math.exp(-beat*22)*math.sin(math.tau*(58*beat+2*(1-math.exp(-beat*35))))*.20
            arp=math.sin(math.tau*chord[int(t/.3)%3]*2*t)*math.exp(-(t%.3)*12)*.07
            dynamic=.55 if section<3 else (1 if section<6 else .65)
            value=(pad+pulse+arp)*envelope*dynamic
            block.append(struct.pack('<h',int(max(-.9,min(.9,value))*32767)))
        w.writeframes(b''.join(block))
print(target)
