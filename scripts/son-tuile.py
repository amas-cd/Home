#!/usr/bin/env python3
# Fabrique app/sons/tuile.wav, le son joué en passant d'un jeu à l'autre. Il est fait pour aller avec les sons d'origine de Home,
# qui sont graves et amples (230 à 700 Hz, de longues résonances) : une note douce autour de 480 Hz, courte, sans glissement
# (un glissement faisait « bulle »), posée par un contact très léger, puis une résonance ample qui s'éteint (réverbération lisse :
# quatre retards en boucle puis deux diffuseurs, adoucie dans l'aigu).
#   python3 scripts/son-tuile.py [SORTIE.wav] [NOTE_HZ=480] [SALLE_S=0.70] [NIVEAU_SALLE=0.34]
import wave, struct, math, sys, random
from pathlib import Path
a = sys.argv[1:]
dest = a[0] if len(a) > 0 else str(Path(__file__).resolve().parent.parent / 'app/sons/tuile.wav')
note = float(a[1]) if len(a) > 1 else 480.0; salle = float(a[2]) if len(a) > 2 else 0.70; niveau = float(a[3]) if len(a) > 3 else 0.34
sr = 44100; random.seed(5)
n = int(0.16 * sr); sec = []; lp = 0.0
for i in range(n):
    t = i / sr
    env = min(1, t / 0.004) * math.exp(-t / 0.034)                                   # attaque adoucie, la note tombe vite
    corps = math.sin(2 * math.pi * note * t) + 0.30 * math.sin(2 * math.pi * 2 * note * t) + 0.10 * math.sin(2 * math.pi * 3 * note * t)
    lp = 0.85 * lp + 0.15 * (random.random() * 2 - 1); contact = lp * math.exp(-t / 0.003) * 0.5   # un contact feutré, pour qu'on sente l'appui
    sec.append(corps * env + contact)
total = int((0.20 + salle * 1.5) * sr); x = sec + [0.0] * (total - len(sec))
def peigne(x, retard, g, amorti=0.55):
    y = [0.0] * len(x); buf = [0.0] * retard; p = 0; l = 0.0
    for i, v in enumerate(x):
        o = buf[p]; l = o * (1 - amorti) + l * amorti; buf[p] = v + l * g; y[i] = o; p = (p + 1) % retard
    return y
def passe_tout(x, retard, g=0.5):
    y = [0.0] * len(x); buf = [0.0] * retard; p = 0
    for i, v in enumerate(x):
        b = buf[p]; o = -g * v + b; buf[p] = v + g * o; y[i] = o; p = (p + 1) % retard
    return y
mouille = [0.0] * total
for r in (1116, 1188, 1277, 1356):                       # des durées qui ne tombent jamais ensemble
    g = 10 ** (-3 * (r / sr) / salle)                    # le son a perdu 60 dB au bout de `salle` secondes
    for i, v in enumerate(peigne(x, r, g)): mouille[i] += v / 4
for r in (225, 556): mouille = passe_tout(mouille, r)
mm = max(abs(v) for v in mouille) or 1; ms = max(abs(v) for v in sec) or 1
out = [x[i] / ms + mouille[i] / mm * niveau for i in range(total)]
fin = int(0.15 * sr)
for i in range(fin): out[total - fin + i] *= 1 - i / fin
mx = max(abs(v) for v in out)
o = wave.open(dest, 'w'); o.setnchannels(2); o.setsampwidth(2); o.setframerate(sr)
o.writeframes(b''.join(struct.pack('<hh', *[int(v / mx * 0.36 * 32767)] * 2) for v in out)); o.close()
print(f'{dest} : {total / sr:.2f} s')
