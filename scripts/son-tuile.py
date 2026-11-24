# Fabrique app/sons/tuile.wav : python3 scripts/son-tuile.py app/sons/banque/switch_004.wav app/sons/tuile.wav 0.55 0.26
# le clic choisi (switch_004, banque Kenney) dans une salle : une réverbération lisse (quatre retards en boucle, puis deux diffuseurs —
# le montage classique de Schroeder), adoucie dans l'aigu. C'est le clic lui-même qui résonne : ni note ajoutée, ni souffle.
import wave, struct, sys
src, dest, duree, niveau = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
w = wave.open(src); n = w.getnframes(); sr = w.getframerate(); ch = w.getnchannels()
brut = struct.unpack('<%dh' % (n * ch), w.readframes(n)); w.close()
sec = [sum(brut[i * ch:(i + 1) * ch]) / ch / 32768 for i in range(min(n, int(0.09 * sr)))]
k = int(0.008 * sr)
for i in range(k): sec[len(sec) - k + i] *= 1 - i / k
total = int((0.12 + duree * 1.6) * sr); x = sec + [0.0] * (total - len(sec))
def peigne(x, retard, g, amorti=0.35):
    y = [0.0] * len(x); buf = [0.0] * retard; p = 0; lp = 0.0
    for i, v in enumerate(x):
        o = buf[p]; lp = o * (1 - amorti) + lp * amorti; buf[p] = v + lp * g; y[i] = o; p = (p + 1) % retard
    return y
def passe_tout(x, retard, g=0.5):
    y = [0.0] * len(x); buf = [0.0] * retard; p = 0
    for i, v in enumerate(x):
        b = buf[p]; o = -g * v + b; buf[p] = v + g * o; y[i] = o; p = (p + 1) % retard
    return y
retards = [1116, 1188, 1277, 1356]                                  # en échantillons : des durées qui ne tombent jamais ensemble
mouille = [0.0] * total
for r in retards:
    g = 10 ** (-3 * (r / sr) / duree)                               # le son a perdu 60 dB au bout de `duree` secondes
    for i, v in enumerate(peigne(x, r, g)): mouille[i] += v / len(retards)
for r in (225, 556): mouille = passe_tout(mouille, r)
mm = max(abs(v) for v in mouille) or 1; ms = max(abs(v) for v in sec) or 1
doux = []; lp = 0.0
for v in x: lp = 0.55 * lp + 0.45 * v; doux.append(lp)                # le clic, aigus rabotés
md = max(abs(v) for v in doux) or 1
out = [(doux[i] / md) * 0.62 + mouille[i] / mm * niveau for i in range(total)]
fin = int(0.10 * sr)
for i in range(fin): out[total - fin + i] *= 1 - i / fin
mx = max(abs(v) for v in out)
o = wave.open(dest, 'w'); o.setnchannels(2); o.setsampwidth(2); o.setframerate(sr)
o.writeframes(b''.join(struct.pack('<hh', *[int(v / mx * 0.30 * 32767)] * 2) for v in out)); o.close()
