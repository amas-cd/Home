# Animations de Home : la référence pour la version Windows

Toutes les valeurs viennent de `app/main.swift` (l'app Mac, qui fait foi). Les durées sont en secondes, les distances en
points sur un écran de 1920 de large (la fenêtre Windows applique déjà cette échelle).

## Les outils côté Avalonia 11

Une courbe SwiftUI `.timingCurve(x1, y1, x2, y2)` est une courbe de Bézier cubique : c'est `SplineEasing` en Avalonia.

```csharp
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Media;
using Avalonia.Media.Transformation;

static class Mouvement
{
    // les deux mouvements de toute l'interface
    public static Easing Glisse => new SplineEasing(0.2, 0.75, 0.2, 1);    // 0,24 s : un choix qui change (pastilles, onglets)
    public static Easing Coule  => new SplineEasing(0.32, 0.0, 0.16, 1);   // 0,42 s : la bibliothèque (tuiles, rangées)
    public static Easing Douce  => new SplineEasing(0.2, 0.8, 0.2, 1);     // la roue des menus, l'écran de démarrage
    public static TimeSpan S(double s) => TimeSpan.FromSeconds(Reduit ? Math.Min(s, 0.12) : s);
    public static bool Reduit;   // « Animations réduites » : tout devient un fondu de 0,10 à 0,12 s, courbe CubicEaseOut

    // une transition par propriété : opacité, transformation (échelle, déplacement), flou
    public static DoubleTransition Opacite(double s, Easing? e = null) => new() { Property = Visual.OpacityProperty, Duration = S(s), Easing = e ?? new CubicEaseOut() };
    public static TransformOperationsTransition Transfo(double s, Easing e) => new() { Property = Visual.RenderTransformProperty, Duration = S(s), Easing = e };
    public static EffectTransition Flou(double s) => new() { Property = Visual.EffectProperty, Duration = S(s), Easing = new CubicEaseInOut() };
}
```

Règles qui évitent les saccades (elles ont été trouvées à la dure sur Mac) :

- **Ne jamais animer `Width` / `Height` d'une image** : elle est redessinée à chaque image. Garder la taille de dessin fixe et
  animer `RenderTransform` (`TransformOperations.Parse("scale(1.34)")`), avec `RenderTransformOrigin` au bon endroit.
- Écrire les transformations avec `TransformOperations.Parse("translate(0px, 236px) scale(1)")` : c'est le seul type que
  `TransformOperationsTransition` sait animer. Les deux états doivent avoir les mêmes opérations dans le même ordre.
- Le flou : `Effect = new BlurEffect { Radius = 14 }`, animé par `EffectTransition`. Mettre `Radius = 0` plutôt que `null` pour
  que la transition ait deux états à relier.
- Une suite d'étapes (écran de démarrage) : `await Task.Delay(...)` puis changement de propriété, chaque élément ayant ses
  propres `Transitions`. Pour une boucle (anneau qui tourne), `new Animation { IterationCount = IterationCount.Infinite, ... }`.
- Les apparitions décalées (« en cascade ») : `Delay = TimeSpan.FromSeconds(i * 0.045)` sur la transition de l'élément `i`.

## La bibliothèque

| Élément | États | Courbe, durée |
|---|---|---|
| Tuile visée | carré de 180 fixe, coins 26 ; `scale(1.34)` ancré **en bas au centre** ; marge horizontale de 0 à 30,6 de chaque côté (180 × 0,34 / 2) pour pousser les voisines ; bord blanc 3 px de 0 à 1 d'opacité ; luminosité de −0,12 à 0 ; ombre rayon 8 → 16, décalage 5 → 10 | `Coule`, 0,42 |
| Rangée de jeux | espace de 22 entre tuiles ; le défilement recentre la tuile visée | `Coule`, 0,42 |
| Catégories (pile de rangées) | chaque rangée est décalée de `d × 236` en vertical (`d` = écart à la catégorie en cours, **circulaire** : après la dernière vient la première) ; `d = 0` : opacité 1, flou 0 ; `d = +1` : opacité 0,45, flou 14 ; `d = −1` : opacité 0, flou 14 ; les autres ne sont pas dessinées | `Coule`, 0,42 |
| Onglets de catégorie | texte en capitales larges 17 ; en cours : opacité 1 et trait blanc 26 × 3 dessous ; autres : opacité 0,5, trait de largeur 0 | `Glisse`, 0,24 |
| Fond (image du jeu) | fondu enchaîné quand le jeu visé change ; zoom lent 1,00 ↔ 1,05 en 30 s, aller-retour sans fin, linéaire | fondu `CubicEaseInOut`, 0,35 |
| Nom, logo et infos du jeu | fondu quand le jeu visé change | `CubicEaseInOut`, 0,40 |
| Arrivée de la bibliothèque | la pile monte de 36 à 0 et passe de 0 à 1 d'opacité, 0,1 s après l'affichage | `SplineEasing(0.2, 0.75, 0.2, 1)`, 0,45 |
| Bibliothèque derrière un menu | flou 0 → 16, échelle 1 → 0,985 | `CubicEaseInOut`, 0,35 |
| Barre de volume du haut | apparaît en descendant de −16 à 0 avec un fondu, repart de la même façon vers le haut au bout de 2 s | `CubicEaseInOut`, 0,50 |

## Les menus

| Élément | États | Courbe, durée |
|---|---|---|
| Rangée de pastilles (menu court) | pastille visée 96 de diamètre, les autres 76 ; halo de la couleur du choix (rayon 26, opacité 0 → 0,75) ; bord blanc 3 px | `Glisse`, 0,24 |
| Arrivée des pastilles | chacune monte de 26 à 0 avec un fondu, la suivante 0,045 s après la précédente | `SplineEasing(0.2, 0.75, 0.2, 1)`, 0,38 |
| Nom du choix sous les pastilles | fondu quand le choix change | 0,22 |
| Roue (menu long) | le choix visé à l'échelle 1 ; le voisin 0,56 ; les suivants 0,46 (ancre à gauche) ; décalage vertical `±(74 + (e − 1) × 50)` pour un écart `e` ; opacités 1 / 0,62 / 0,40 / 0,24 / 0,12 ; au-delà de 6 d'écart, pas dessiné | `Douce`, 0,22 |
| Arrivée de la roue | glisse de 46 à 0 en horizontal (depuis la droite ; depuis la gauche quand on revient en arrière) avec un fondu | `SplineEasing(0.2, 0.75, 0.2, 1)`, 0,36 |
| Panneau de droite de la roue (disque ou jaquette) | l'ancien s'efface, le nouveau arrive en fondu depuis l'échelle 0,94 | `CubicEaseOut`, 0,18 |
| Halo coloré derrière le panneau | change de couleur avec le choix | `CubicEaseInOut`, 0,45 |
| Fond du menu | noir de 0 à 0,55 d'opacité | `CubicEaseOut`, 0,25 |
| Appui sur un choix | l'ensemble passe à l'échelle 0,995 puis revient | ressort court (0,18 s, peu de rebond) |
| Grille des mods | affiche visée à l'échelle 1,04, les autres assombries de 0,10 | `CubicEaseOut`, 0,14 |
| Apparence (choix d'image) | image visée à l'échelle 1,06 ancrée en bas, les autres assombries de 0,15 ; une image n'apparaît qu'une fois chargée, en fondu de 0,35 | `CubicEaseOut`, 0,14 |

## L'écran de démarrage (2,15 s, puis sortie)

Fond `rgb(5, 5, 13)`. Tout part au temps 0 ; chaque ligne a son propre délai.

| Temps | Élément | Mouvement | Courbe, durée |
|---|---|---|---|
| 0,00 | trois lueurs (violet, bleu, orange, flou 170) | opacité 0 → 0,50, elles s'écartent du centre | `CubicEaseOut`, 1,2 |
| 0,00 | tout le bloc central | échelle 1 → 1,06, pour que rien ne se fige | linéaire, 3,4 |
| 0,10 | carte centrale (190 × 262, coins 34) | échelle 0,72 → 1, opacité 0 → 1 | `Douce`, 0,7 |
| 0,50 | deux cartes derrière | rotation 0 → ±15°, décalage 0 → ±92 en x et 14 en y | `Douce`, 0,6 |
| 0,80 | manette sur la carte | échelle 0,5 → 1, opacité 0 → 1 | `Douce`, 0,45 |
| 0,80 | deux anneaux (300 de diamètre) | échelle 0,7 → 3,4 et 0,5 → 2,4, opacité 0,5 et 0,35 → 0 | `CubicEaseOut`, 1,3 |
| 1,00 | « HOME » (54, capitales larges) | espacement des lettres 44 → 14, opacité 0 → 1 | `Douce`, 0,7 |
| 2,15 | sortie du bloc central | échelle × 1,12, opacité → 0 | `CubicEaseIn`, 0,6 |
| 2,15 | sortie du fond | opacité → 0 pendant que la bibliothèque apparaît dessous | `CubicEaseInOut`, 0,9 |
| 3,15 | la vue est retirée | | |

Une touche ou un bouton passe l'écran (même sortie), **sauf pendant la première 1,5 s** : les appuis parasites d'une manette
qui se réveille ne doivent ni le couper ni lancer un jeu. Le jingle `app/sons/lancer.wav` part au temps 0.

## L'avancement d'une tâche (pastille en bas à droite)

| Élément | États | Courbe, durée |
|---|---|---|
| Arrivée | monte de 16 à 0 avec un fondu | ressort doux, 0,6 |
| Départ | s'efface en se floutant : flou 0 → 20, opacité → 0, échelle → 0,97 | `CubicEaseInOut`, 0,5 à 0,6 |
| Anneau (44 de diamètre, trait 4, bouts ronds) | l'arc suit l'avancement, départ en haut | `CubicEaseInOut`, 0,9 |
| Anneau sans mesure | un arc de 28 % qui fait un tour | linéaire, 1,1 par tour, sans fin |
| Pourcentage | les chiffres changent en fondu | `CubicEaseOut`, 0,4 |
| Fin ou échec | le bord passe au vert ou à l'orange | `CubicEaseInOut`, 0,35 |

## Sons liés aux mouvements

`deplacer` à chaque changement de choix, `onglet` au changement de catégorie, `volume` à chaque cran de 5 % du volume (manette
ou souris), `valider`, `retour`, `ouvrir`, `lancer`. Les trois premiers se coupent l'un l'autre avec un fondu de 50 ms : un
appui maintenu ne doit pas empiler les sons.
