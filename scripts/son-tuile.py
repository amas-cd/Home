#!/usr/bin/env python3
# Fabrique app/sons/tuile.wav, le son joué en passant d'un jeu à l'autre : le son « scroll_001 » de la banque Kenney (CC0), choisi par
# Anas, rendu à peine plus grave et « profond » — il résonne dans une salle (réverbération lisse : quatre retards en boucle puis deux
# diffuseurs, adoucie dans l'aigu). Ni note ajoutée, ni souffle : c'est le son lui-même qui résonne.
#   python3 scripts/son-tuile.py [SOURCE.wav] [SORTIE.wav] [GRAVE=0.94] [SALLE_S=0.85] [NIVEAU_SALLE=0.46]
import wave, struct, sys
from pathlib import Path
ici = Path(__file__).resolve().parent.parent
a = sys.argv[1:]
src = a[0] if len(a) > 0 else str(ici / 'app/sons/banque/scroll_001.wav'); dest = a[1] if len(a) > 1 else str(ici / 'app/sons/tuile.wav')
grave = float(a[2]) if len(a) > 2 else 0.94; salle = float(a[3]) if len(a) > 3 else 0.85; niveau = float(a[4]) if len(a) > 4 else 0.46
w = wave.open(src); n = w.getnframes(); sr = w.getframerate(); ch = w.getnchannels()
brut = struct.unpack('<%dh' % (n * ch), w.readframes(n)); w.close()
mono = [sum(brut[i * ch:(i + 1) * ch]) / ch / 32768 for i in range(n)]
# à peine plus grave : le son est relu un peu plus lentement (0,94 = environ un demi-ton plus bas)
sec = []
k = 0.0
while k < len(mono) - 1:
    i = int(k); f = k - i; sec.append(mono[i] * (1 - f) + mono[i + 1] * f); k += grave
fondu = min(len(sec), int(0.008 * sr))
for i in range(fondu): sec[len(sec) - fondu + i] *= 1 - i / fondu
total = len(sec) + int((0.10 + salle * 1.5) * sr); x = sec + [0.0] * (total - len(sec))
def peigne(x, retard, g, amorti=0.40):
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
fin = int(0.10 * sr)
for i in range(fin): out[total - fin + i] *= 1 - i / fin
mx = max(abs(v) for v in out)
o = wave.open(dest, 'w'); o.setnchannels(2); o.setsampwidth(2); o.setframerate(sr)
o.writeframes(b''.join(struct.pack('<hh', *[int(v / mx * 0.40 * 32767)] * 2) for v in out)); o.close()
print(f'{dest} : {total / sr:.2f} s')
