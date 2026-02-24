#!/bin/bash
# beep.sh — play three simple beeps

beep_sox() {
    for i in 1 2 3; do
        sox -n -t alsa default synth 0.2 sine 1000 vol 0.5
        sleep 0.3
    done
}

beep_speaker() {
    for i in 1 2 3; do
        beep -f 1000 -l 200
        sleep 0.3
    done
}

beep_paplay() {
    # generate a WAV file in /tmp and play via PulseAudio
    python3 -c "
import struct, math, wave, tempfile, os
rate=44100; freq=440; dur=0.2
samples=[int(32767*math.sin(2*math.pi*freq*i/rate)) for i in range(int(rate*dur))]
path='/tmp/beep_tone.wav'
with wave.open(path,'w') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    w.writeframes(struct.pack('<'+'h'*len(samples),*samples))
print(path)
"
    paplay /tmp/beep_tone.wav
}

beep_aplay() {
    # generate a raw PCM tone (440 Hz, 0.2s, 44100 Hz, mono, 16-bit)
    python3 -c "
import struct, math
rate=44100; freq=440; dur=0.2
samples=[int(32767*math.sin(2*math.pi*freq*i/rate)) for i in range(int(rate*dur))]
import sys; sys.stdout.buffer.write(struct.pack('<' + 'h'*len(samples), *samples))
" | aplay -r 44100 -f S16_LE -c 1 -q
}

beep_three_pa() {
    for i in 1 2 3; do
        beep_paplay
        sleep 0.3
    done
}

beep_three() {
    for i in 1 2 3; do
        beep_aplay
        sleep 0.3
    done
}

echo "Trying to beep three times..."

if command -v sox &>/dev/null; then
    echo "Using sox"
    beep_sox
elif command -v beep &>/dev/null; then
    echo "Using beep"
    beep_speaker
elif command -v paplay &>/dev/null && command -v python3 &>/dev/null; then
    echo "Using paplay + python3"
    beep_three_pa
elif command -v aplay &>/dev/null && command -v python3 &>/dev/null; then
    echo "Using aplay + python3"
    beep_three
else
    echo "No audio tool found. Install sox, beep, or alsa-utils."
    exit 1
fi

echo "Done!"
