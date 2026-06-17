# NaviHelper — Karten-Route & Wegpunkte (Plan)

Stand: 2026-06-15. Plan-Modus-Ergebnis (software-planning). SSoT für das Feature.
Code erst nach Abnahme.

## Umsetzungsstand (2026-06-16)
- **P0** erledigt (getPathFromToWorld-Arg-Bug, getCurrentPathFromVehicle-Bug). Commits 4bab22d, cfec383.
- **P1** entfällt: alte `mapClickToWorld`-Mathe komplett rausgeworfen statt verifiziert.
  Stattdessen `InGameMenuMapFrame.onClickMap`-Hook (liefert Weltkoordinaten direkt,
  wie WayPointGPS) — robust, kein Selbstbau-Transform mehr.
- **P2 + P3** in einem Rutsch gebaut (v1.2.0.0): Hook umgestellt, `route[]`-Struktur
  mit `targetX/Z`-Shim, Prioritäts-Umkehr (manuelle Route vor AD), Cache-Invalidierung
  bei jeder Mutation, `buildRoutePath` (Hybrid pro Segment: AD-Straße sonst Linie),
  Strg+Klick = Punkt setzen (1. = Ziel, weitere = Zwischenpunkt davor),
  Umschalt+Klick = letzten Punkt löschen. Alt+M ist nur noch ein Hinweis.
  **Braucht In-Game-Test** (nur Markus kann das).
- **P4** (Klick-auf-Punkt löschen, Drag verschieben) noch offen.
- Risiko-Hinweis für den Test: `onClickMap`-Signatur exakt von WayPointGPS übernommen
  `(frame, element, worldX, worldZ)`; Modifier mit keyEvent-Flag + isKeyPressed-Fallback.

## Ziel
NaviHelper von „AutoDrive ist Pflicht-Unterbau" zu „AutoDrive ist eine Quelle"
umbauen: vollwertige Karten-basierte Routenplanung, optional mit Zwischen-Wegpunkten,
Google-Maps-artiges Editieren auf der Karte.

## Entscheidungen (vom Nutzer bestätigt)
- **Priorität:** Manuelle Karten-Route gewinnt, wenn gesetzt. AD-Ziel nur als
  Fallback (kehrt die bisherige Reihenfolge um — bisher AD zuerst).
- **Reihenfolge:** Fahrzeug → Zwischenpunkte in Klickreihenfolge → Ziel.
  Der 1. Klick ist das Endziel (zuletzt angefahren), jeder weitere ein
  Zwischenpunkt davor.
- **Routing:** Hybrid — pro Segment AD-Straßenrouting wenn AutoDrive vorhanden,
  sonst gerade Linie.
- **Persistenz:** Nur zur Laufzeit (kein Savegame).
- **Karten-Interaktion (revidiert 2026-06-16):** KEIN Alt+M-Modus mehr. Punkte
  werden direkt in der großen ESC-Karte per Modifier-Klick gesetzt (wie
  WayPointGPS: Strg+Linksklick — am Mac ggf. Alternative, da Ctrl+Click dort
  Rechtsklick ist; beim Bauen testen). Kein Modus-State, kein versehentliches
  Setzen durch normalen Klick. Alt+M / mapSelectionMode entfällt; die Action kann
  als optionaler Zweitweg bleiben oder raus.
- (verworfen) ~~Klick-Modus per Alt+M, bleibt bis Karte zu~~ — durch
  Modifier-Klick-direkt ersetzt, intuitiver + kein Mac-Alt-Problem.
- **Editieren (Google-Maps-Stil):** Klick auf leere Stelle = neuer Punkt; Klick auf
  bestehenden Punkt = löschen; Drag auf Punkt = verschieben.

## Architektur
Zweite, AD-unabhängige Ziel-Quelle. `getEffectiveTarget` neue Priorität:
manuelle Route (route nicht-leer) → AD-Ziel → nichts. Route wird zu einer Polyline
(`pathNodes`) übersetzt (hybrid pro Segment). Bestehende Render-Kette
(`computeNavData` / `drawRouteLine` / `drawHud`) bleibt unverändert und nutzt diese
`pathNodes`.

## Datenstruktur
`vehicleTargets[key]` von `{targetX,targetZ,pathNodes}` →
`{ route = {p1..pn}, pathNodes, dirty }`. `route` in Anfahr-Reihenfolge,
letztes Element = Endziel, Punkte `{x,z}`. **Kompat-Shim:** Endziel `route[#route]`
zusätzlich nach `slot.targetX/targetZ` spiegeln, damit der bestehende
Distanz-/Reached-Code unverändert läuft (statt 5+ Fundstellen zu migrieren).

## Kritik-Fixes (aus Stage-4-Review, im Plan verankert)
- **Bestands-Bug zuerst:** `updateRoute` ruft `getPathFromToWorld` mit falscher
  Arg-Reihenfolge (übergibt `NaviHelperAD` als 1. Koordinate) → pcall schluckt den
  Fehler → AD-Routing für manuelle Ziele lief nie, alles war Luftlinie. Fixen +
  per Log verifizieren, BEVOR `buildRoutePath` darauf baut.
- **Cache-Invalidierung:** Bei jeder Routen-Mutation (Klick/anhängen, Punkt
  löschen/verschieben, Wegpunkt erreicht, clear) `lastEffectiveTarget=nil` und
  `lastDistanceUpdateTime=0` setzen — sonst fühlt sich jeder Klick ~4s tot an.
- **Eine Reached-Logik:** Wegpunkt-Erreichen nur in `update()`, nicht zusätzlich in
  `drawForVehicle`. Draw mutiert keinen State. Distanz zum nächsten Wegpunkt =
  Luftlinie Fahrzeug→`route[1]` (separat), NICHT `distTotal` (das ist zum Endziel).
- **mapClickToWorld:** Koordinaten-Mathe ist verdächtig (Terme heben sich zu
  `relX*sizeX` auf) und ungetestet. Isoliert verifizieren, bevor Multi-Klick
  draufkommt (sonst multipliziert sich der Fehler pro Klick).
- **getCurrentPathFromVehicle:** latenter `or nil, nil`-Präzedenz-Bug — bei
  Gelegenheit mitnehmen.
- **y-Mischpfad** (AD-y vs. Linie-y=0): bekannte kosmetische Einschränkung
  (Terrain-Fallback in drawRouteLine fängt's grob).

## Phasen (jede für sich testbar)
- **P0 — Fundament:** `updateRoute`-Aufruf-Bug + `getCurrentPathFromVehicle`-Bug
  fixen. Test: manuelles Einzelziel mit AD liefert Straßen-Route statt Luftlinie
  (Log + Spiel).
- **P1 — Karten-Koordinaten:** `mapClickToWorld` isoliert verifizieren (Klick →
  `wx,wz` loggen, Fahrzeug hinfahren, vergleichen), ggf. fixen. Test: Klick =
  korrekte Weltposition.
- **P2 — Durchstich Einzelziel:** Priorität umdrehen (Karte vor AD),
  Cache-Invalidierung, `route[]`-Struktur + Shim. Test: Alt+M, 1 Klick →
  Pfeil/Distanz/Linie zum Ziel, mit UND ohne AD.
- **P3 — Multi-Waypoint:** `buildRoutePath` (Hybrid-Segment-Konkatenation, dedupe),
  Modus bleibt offen bis Karte zu, weitere Klicks = Zwischenpunkte vor Ziel,
  Reached-Weiterschaltung in `update()`. Test: mehrere Klicks → Route über
  Zwischenpunkte, schaltet beim Erreichen weiter.
- **P4 — Editor:** `worldToMapScreen` für Hit-Test, Drag-State im Map-Hook;
  Klick-auf-Punkt = löschen, Drag = verschieben. Test: Punkt anklicken → weg,
  ziehen → verschoben.

## Berührt
Nur `scripts/NaviHelper.lua` (+ evtl. 1–2 l10n-Keys für Modus-Notification).
`AutoDriveBridge.lua` unverändert (defensiv genug). Keine neue Datei.
Settings: Wegpunkt-Erreichen-Schwelle (~8m) als Tuning-Wert ins Settings-Modul.

---

# Vanilla-Spline-Router — NaviHelper-eigenes Pathfinding (Plan, 2026-06-16)

Stand: Plan-Modus (software-planning). SSoT. Kein Code bis Abnahme.

## Ziel & Anspruch
NaviHelper soll auf **jeder** Karte routen — ohne dass der Spieler AutoDrive-Kurse
aufzeichnet. Quelle: das mit der Map ausgelieferte Vanilla-Straßennetz
(`g_currentMission.aiSystem.roadSplines`). Anspruch: **NaviHelper first, AutoDrive
optional/zweite Wahl.**

## Entscheidungen (Nutzer, 2026-06-16)
- **Modus:** jetzt nur Route zeigen (Nav-Aid), **bald auch autonom fahren** →
  Router muss von Rendering UND Fahren entkoppelt bleiben (reine Pfad-Funktion).
- **Priorität:** eigener Vanilla-Router ZUERST, AD nur optional dahinter.
- **Ziele abseits Straßen:** idealerweise die Feld-Einfahrt treffen; wenn nicht
  ermittelbar → nächster Straßenpunkt + Luftlinie aufs Feld.
- **Zukunft:** denselben Graphen als Bootstrap-Grundnetz für AD-Kurse exportieren
  (Spieler legt dann „nur" noch Haltestellen fest + optimiert).

## Machbarkeit (am AD-Quellcode verifiziert)
- `aiSystem.roadSplines` existiert; `getSplineLength` / `getSplinePosition(spline, t∈[0,1])`
  liefern die Geometrie. AD liest das in `TrafficSplineUtils.adParseSplines`.
- Graph-Bau-Rezept von AD adaptierbar: Spline sampeln (adaptive Dichte — in Kurven
  enger), Dual-Roads via deckungsgleiche Start/End-Punkte, Kreuzungen via
  zusammenfallende Spline-Enden zusammenschweißen.
- **OFFEN (Spikes):** (1) Sind `roadSplines` auf Mechet/Helden/Weipersdorf
  überhaupt befüllt? = Go/No-Go. (2) Gibt es eine Feld-Einfahrt-API? AD nutzt keine
  → Default-Fallback „nächster Knoten".

## Architektur
Neues, **reines** Modul `RoadGraph` (keine Render-/Fahr-Seiteneffekte):
- `build()` — `roadSplines` → Knoten (gesampelt) + Kanten (aufeinanderfolgend +
  Kreuzungs-Welds). Einmal pro Map, **lazy** beim ersten Routen-Request.
  Spatial-Index (Grid-Buckets) für schnelles `findNearestNode`.
- `findNearestNode(x,z)` — mit Max-Snap-Distanz.
- `findPath(sx,sz, dx,dz)` — beide Enden snappen, **A\*** über den Graphen,
  Welt-Polyline zurück; echte Start/Ziel-Punkte als Luftlinien-Anschluss vorn/hinten.

Router-Priorität in `buildRoutePath` (pro Segment): **RoadGraph → AD (optional) →
Luftlinie.** Das Rendering (HUD / Karten-Dots / Bodenlinie) bleibt unverändert und
konsumiert weiter `pathNodes`. Entkopplung = späterer Fahr-Controller und
AD-Bootstrap-Export hängen an denselben `pathNodes` bzw. demselben Graphen.

## Dateien
- **NEU** `scripts/RoadGraph.lua` (Graph, A\*, Spatial-Index). In `register.lua`
  VOR `NaviHelper.lua` sourcen.
- **EDIT** `scripts/NaviHelper.lua`: `buildRoutePath` nutzt RoadGraph zuerst;
  `loadMap` stößt Lazy-Build an; Diagnose-Logs.
- `AutoDriveBridge.lua` unverändert (bleibt optionaler Zweig).

## Datenfluss
Klick → `route[]` → `updateRoute` → `buildRoutePath` (pro Segment: RoadGraph.findPath
→ AD → Linie) → `pathNodes` → draw (Boden + Karte)  [+ später: Fahr-Controller].

## Fehlerquellen
- `roadSplines` leer → kein Graph → AD/Linie-Fallback (geloggt).
- Graph-Baukosten auf großer Map → lazy + Sampling + Spatial-Index; ggf.
  Zeitbudget/chunked (Risiko, bewusst später).
- Getrennte Komponenten (Start/Ziel auf verschiedenen „Inseln") → A\* scheitert →
  Fallback.
- Snap-Distanz zu groß → langer Luftlinien-Stummel; cappen.
- Weld-Toleranz Kreuzungen: zu eng = zerrissener Graph, zu lose = Fehlverbindung.
  Tunebar (Settings).

## Phasen (jede für sich testbar)
- **R0 — Spike:** `#roadSplines` + Beispielgeometrie auf Mechet/Helden/Weipersdorf
  loggen. **Go/No-Go.**
- **R1 — Graph-Bau + Debug-Overlay:** ganzen Graphen auf der Karte zeichnen →
  visuell gegen die Straßen prüfen.
- **R2 — A\* + Snapping + RoadGraph-first:** Klick auf einer Map OHNE AD-Kurs →
  echte Straßenroute (Boden + Karte).
- **R3 — Feld-Einfahrt:** Spike API; sonst Nächster-Knoten-Fallback.
- **R4 (separat, später):** autonomes Fahren (Fahr-Controller auf `pathNodes`).
- **R5 (separat, später):** AD-Kurs-Bootstrap-Export aus dem Graphen.

## Berührt nicht
Map-Route/Editor (P2/P3, P4) bleibt. Router ist nur eine zusätzliche, priorisierte
Pfad-Quelle. AD-Bridge bleibt als optionaler Zweig erhalten.

## Kritik-Fixes (Stage-4-Review, eingearbeitet)
- **(hoch) R0 verschärfen:** nicht „roadSplines befüllt ja/nein", sondern auf den
  ECHTEN Maps des Nutzers (Mechet, Helden, Weipersdorf) messen: Anzahl Splines,
  Gesamtlänge, und ob das Netz Felder/Höfe erschließt oder nur eine Hauptstraße ist.
  Begründung: dieselben Hobby-Mapper, die keine AD-Kurse pflegen, setzen oft auch
  das Vanilla-AI-Netz nur lückenhaft. Wenn R0 dünn ausfällt, ist die ehrliche Lösung
  ein leichtgewichtiges „selbst ein paar Wegpunkte setzen", nicht R1–R3 für die Tonne.
- **(hoch) Kein onclick-Freeze:** Graph-Bau NICHT synchron an den ersten Klick
  koppeln (= sichtbarer Hänger genau bei Nutzeraktion). Stattdessen zeitlich
  entkoppelt: Build nach Map-Load über mehrere Frames in `update` mit Zeitbudget
  (z.B. ~2 ms/Frame), Routing erst wenn „ready", bis dahin Luftlinie. Sample-Auflösung
  = Parameter, der die Knotenzahl deckelt.
- **(mittel) Reroute-Policy = statisch:** Route wird EINMAL beim Zielsetzen berechnet,
  bleibt bis neues Ziel. Off-Route-Neuberechnung nur hart gethrottelt (Abstand zur
  Linie > Schwelle, max. alle N s) — damit sind A\*-Kosten ein Non-Issue.
- **(mittel) Welding robust:** exaktes/quasi-exaktes Endpunkt-Matching wie AD (kleine
  Epsilon-Toleranz), KEIN großzügiges Fuzzy-Snapping; Y-Differenz separat hart
  begrenzen (Brücke/Unterführung dürfen nicht verschmelzen, sonst routet's in den Fluss).
- **(mittel) Graph ungerichtet, Dual-Road-Detection weglassen:** Richtung ist fürs
  reine Anzeigen (Mensch am Lenkrad) irrelevant. Dual-Road/Richtung erst bei R4
  (autonomes Fahren). Spart AD-Komplexität, die R0–R3 nicht braucht.
- **(niedrig) Sichtbares Fallback-Signal:** Rendering unterscheidet echte Straßenroute
  vs. Luftlinien-Fallback (Farbe/gestrichelt) — sonst wirkt „mal Route, mal nicht" kaputt.
- **(niedrig) R3 entschärft:** der Luftlinien-Anschluss Knoten→Klickpunkt IST schon die
  Einfahrt-Näherung. Echte Feld-Zufahrt über Feldgrenzen-Geometrie ist ein eigenes,
  schweres Problem (kein Spline-Thema) → nach hinten/optional, nicht Teil des Durchstichs.

## Revidierte Phasen (Spline-Ansatz — teilweise überholt, siehe unten)
- **R0 — Spike (Go/No-Go):** ERLEDIGT. roadSplines tragen auf allen drei Maps
  (Mechet 134 Splines/36 km/~100 %, Helden 19/12,6 km/~65 %, Weipersdorf 13/6 km/~85 %).
- **R1 — Graph-Bau + Debug-Overlay:** ERLEDIGT (RoadGraph.lua). Aber: nur 1 Kreuzung
  verschweißt → Graph fragmentiert; UND das Traffic-Netz deckt Dorf/Feldwege nicht ab.
  → Richtungswechsel, siehe nächster Block.
- ~~R2 Spline-A\*~~ — verworfen als Primärweg (Coverage-Lücke Dorf/Feldwege).

---

# Richtungswechsel: Grid-Bake-A\* (Nutzer-Entscheidung 2026-06-16)

## Datenquellen-Befund (per Laufzeit-Probe, nhProbe/nhProbeNav)
- `aiSystem.roadSplines` = Ambient-Traffic-Netz: Hauptstraßen, KEINE Dorf-Innereien/Feldwege.
- `aiSystem.navigationMap` = **Kollisions-Geometrie** (`navigationCollision`), KEIN lesbarer
  Bit-Vector (`getBitVectorMapPoint` liefert nil). Engine testet „befahrbar" per Physik
  gegen `aiDrivableCollisionMask=16384` / `obstacleCollisionMask=32`.
- **Kein** „Pfad A→B" nach Lua freigelegt (Pathfinding steckt in AI-Jobs/C++).
- ABER vorhanden: `AISystem:getIsPositionReachable`, interne Planungs-Cost-Map
  (`setPlanningBitVectorMap`, `consoleCommandAICostmapExport`), und Kollisions-Primitive
  `overlapBox` / `overlapSphere` / `raycastClosest` (alle =true).

## Ansatz
Eigenes **Befahrbarkeits-Gitter einmal pro Map vorbacken** (Drivability-Orakel per
Kollisions-/Reachability-Abfrage), dann **A\* über das Gitter**. Volle Abdeckung
(Dorf, Höfe, Feldwege, Felder) auf jeder Karte, AD-unabhängig. Rendering/Route-Struktur
bleibt wie gebaut (pathNodes). RoadGraph/Splines bleiben optionaler Fallback.

## Phasen (jede testbar)
- **G0 — Orakel-Spike (Go/No-Go):** `getIsPositionReachable`-Signatur klären + an
  bekannt-befahrbaren vs. Wasser/Gebäude-Punkten testen; Kosten pro Abfrage grob messen
  (entscheidet Bake-Auflösung). Fallback-Orakel: `overlapBox` mit aiDrivableCollisionMask.
- **G1 — Bake + Overlay:** Gitter (z.B. 4–8 m Zellen) zeitbudgetiert über Frames backen,
  als Heatmap auf der Karte zeichnen → visuell gegen befahrbares Gelände prüfen.
- **G2 — A\* auf dem Gitter:** Klick-Ziel → Pfad über befahrbare Zellen (Boden + Karte),
  Fallback-Signal. Statische Route, Reroute gethrottelt.
- **G3 — Glätten + Feld-Einfahrt:** Pfad glätten (keine Treppchen), letzte Zelle →
  Feldpolygon/teleportNode.
- **G4/G5 (später):** autonomes Fahren · AD-Kurs-Bootstrap-Export.

## Risiken (für G0/G1 im Auge behalten)
- Bake-Kosten: 2048 m / Zellgröße. 8 m → 256×256 = 65k Abfragen; 4 m → 512×512 = 262k.
  Zeitbudgetiert über viele Frames, einmalig. Orakel-Kosten aus G0 bestimmt die Zellgröße.
- Orakel-Korrektheit: „befahrbar" muss Straße/Feld JA, Wasser/Wald/Gebäude NEIN liefern.
- Speicher: Gitter als Bitfeld/Byte-Array (65k–262k Einträge) — unkritisch.
- A\*-Kosten auf großem Gitter: Heuristik + nur Korridor expandieren; einmal pro Ziel.

### G0/G1-Befund (verworfen als Primärweg)
`getIsPositionReachable(x,y,z)` ist spottbillig (~0,0004 ms), aber **zu grob**: liefert
~92 % „erreichbar" — Feld, Wiese, Waldboden, Straße alles gleich. Findet KEINE Straßen.
Heatmap bestätigt: fast alles grün. → Grid/Reachable als Straßen-Quelle verworfen.

---

# Richtungswechsel 2: Straßengraph aus dem Overview-Bild (Nutzer-Idee, 2026-06-16)

## Idee
Offline/async aus dem Map-Overview (`maps/.../overview.dds`, top-down) das Straßennetz
per Bildverarbeitung extrahieren → Graph pro Map vorbacken → ausliefern. In-Mod nur
laden + A\*. „Deluxe nur für processed maps", batchbar über ModHub. Folgt echten Straßen
(weil der Graph die Straßen IST), volle Abdeckung inkl. Dorf/Feldwege.

## Pipeline (Tool: `tools/roadgraph/extract.py`, Python)
overview.dds → RGB → Straßen-Maske (Farbe) → Cleanup → Skelettieren → sknw-Vektorisierung
→ Graph (Knoten/Kanten) in Weltkoordinaten als JSON + Debug-Overlay-PNG.
Deps: pillow, numpy, scikit-image, sknw, networkx.

## Befund (3 Maps getestet)
- **Helden (sauber stilisiert):** VOLLTREFFER — Netz exakt auf allen Wegen, 905 Knoten,
  ~13,8 km, sauber vektorisiert. Beweist die Idee.
- **Mechet:** stilisiert ABER mit Deko-Schreibtisch-Rahmen + kontrastarm → simpler
  Threshold/Crop überläuft (Rahmen = „Straße"). (NICHT fotoreal — anfangs falsch gelabelt.)
- **Weipersdorf:** stark texturiert/gemalt, Straßen blass im Wald-Rauschen → Threshold
  chancenlos.
- **Lehre:** Overview-Stil ist autorabhängig/uneinheitlich. Robuster General-Extraktor =
  eigenes CV-Projekt, am ehesten **ML-Straßensegmentierung** (Luftbild→Maske).

## POC-H Ergebnis (2026-06-17) — Pipeline läuft end-to-end, Extraktion zu lückenhaft
Die ganze Kette funktioniert: extract.py → roadgraphs/Helden.lua (721 Knoten) →
RoadGraphFile.lua (laden + A* + nearest-snap) → buildRoutePath (road-graph-first) →
Bodenlinie auf Geländehöhe. Im Log: `astar=7 nodes`, `Route built: … road-graph`.
Routenpunkte gegen das Overview geplottet (outputs/route_on_overview.png): der
A*-Teil liegt **korrekt auf der Straßen-Kreuzung**. ABER: Fahrzeug (37 m) und Klick-Ziel
(131 m) snappen weit auf den nächsten erfassten Knoten → lange Luftlinien-Stummel quer
übers Feld. Ursache: simpler Farb-Threshold **verfehlt dünne Feldwege/Dorfpfade**, daher
große Snap-Distanzen. Fixes (Reihenfolge offen):
- bessere Straßen-Erkennung (ML-Segmentierung ODER getunte CV) für vollständigere Tracks,
- Snapping richtungsbewusst (nicht nach hinten),
- evtl. Off-road-Anschluss übers Drivability-/Gelände statt stur Luftlinie.
Fixes committet bis 1dbb875. Mechanik steht; nächster Hebel = Graph-Vollständigkeit.

## DURCHBRUCH (2026-06-17): Terrain-Farbe = Wege-Erkennung (wie WayPointGPS)
Markus' Hartnäckigkeit ("WayPointGPS macht's doch einfach") aufgedeckt: WayPointGPS liest
das **Terrain-Material/-Farbe** via `getTerrainAttributesAtWorldPos(terrainRootNode,x,y,z,
true,true,true,true,false)` → r,g,b + materialId. Maps ohne Material-Namen (wie Helden) →
**Farb-Fallback: grau = Weg.** Per VTRACK+Farbe bewiesen:
- Hauptstraße + Dorfstraße + **Feldweg**: alle grau, rgb≈0.284/0.284/0.284, **Sättigung 0.00**.
- Acker: braun, rgb≈0.155/0.082/0.037, **Sättigung 0.76**. Glasklare Trennung.
- Grau-Sweep @12m: 1323/29241 Zellen grau (4,5 %) = Wege-Netz-Größe. Abfrage ~0.0004ms.

### NEUER PLAN (ersetzt Bild/Kalibrierung/Spline)
Grid-Pathfinding über **graue Terrain-Zellen**, Grau-Check live per
`getTerrainAttributesAtWorldPos` (Sättigung < ~0.18). Engine-Koordinaten, KEINE
Kalibrierung, KEIN Bild, KEIN Spline, **jede Map sofort** (Hof/Dorf/Feldwege inklusive).
- T0: Grau-Orakel verifiziert (✓ 4,5 %, sauber getrennt).
- T1: A* auf virtuellem Grid (~6–8 m Zellen), Zelle befahrbar = grau; Start/Ziel auf
  nächste graue Zelle snappen; Abfrage on-demand (billig, kein Bake noetig).
- T2: Pfad glätten + an bestehende Route/HUD/Karten-Anzeige hängen.
- T3 optional: Feldwege (anderes Material/Farbe) teurer gewichten als Hauptstraßen;
  Material-Namen nutzen wo vorhanden.
- Bild-Pipeline (extract.py/fit_calib/Helden.lua/RoadGraphFile) + Spline-Scan → eingemottet
  (Code bleibt als Referenz/Fallback, inaktiv).

## Spline-Inventur Helden (2026-06-17) — Bild-Weg war Sackgasse (s.o. Durchbruch)
Frage: liefert der WayPointGPS-Spline-Weg auch Dorfstraßen/Feldwege ohne KI-Verkehr?
nhSplines-Probe (scannt aiSystem + trafficSystem.rootNodeId + Szenen-Graph):
- aiSystem.roadSplines: 19 Splines, 12.638 m (SHAPE-Check ok=19).
- trafficSystem.rootNodeId: 2 Splines, 12.043 m. Sonst im Szenen-Graph: 0.
- = alles dasselbe Haupt-Verkehrsnetz (~12 km). Dorfstraßen + Feldwege sind auf Helden
  **NUR TEXTUR, keine Splines** → kein Spline-Ansatz (auch WayPointGPS nicht) findet sie;
  WPGPS fällt dort auf Luftlinie/Terrain zurück.
ENTSCHEIDUNG: Bild-Extraktion + Kalibrierung BLEIBT der Hauptweg (einzige Quelle für die
textur-gemalten Wege). Spline-Scan höchstens als optionale Zusatzquelle/Fallback für Maps
mit fotoreal/texturiertem Overview. Der „Umweg" war berechtigt.

## POC-H Update 2 (2026-06-17): Kalibrierung gelöst, jetzt Graph-Inhalt
DURCHBRUCH: Overview↔Engine war ~174° gedreht + 1.551 px/m skaliert (Welt ~2641m >
Terrain). Per VTRACK-Fahrspur (84 Punkte) mit fit_calib.py (ICP-Similarity) registriert,
Graph in Engine-Koords neu gebacken. Snapping jetzt START 4m / DEST 9m (vorher 145m+),
A* 75 Knoten, untere Routenhälfte folgt sauber der Straße. Tooling: tools/roadgraph/
fit_calib.py, extract.py --calib, Helden.calib.txt. Commit ac0da67.
VERBLEIBEND (klar umrissen): Graph enthält Feld-INTERNE Wege (gestrichelte Tracks) →
A* mäandert durch Felder statt Straße. Nächste, fokussierte Schritte:
1. Feld-Innenspuren aus der Maske filtern (gestrichelt vs durchgezogen; oder Feldpolygone).
2. Kanten als Straße/Feldweg klassifizieren → A* gewichtet Feldwege teurer.
3. Snap auf nächste Kante (Projektion), nicht nur Knoten.
Calibration ist per-Map (jede Map eigene Rotation/Skalierung/Offset) → VTRACK+fit pro Map.

## Nächste Schritte (älter)
- **POC-H (jetzt-ish):** Helden zu Ende: Spurs prunen + nahe Knoten mergen (sknw-Graph
  ist überspurst), Pixel→Welt-Orientierung gegen bekannte Punkte verifizieren, In-Mod-Loader
  (`scripts/RoadGraphFile.lua` lädt die JSON) + A\* drüber, Route zeichnen. = erste echte
  „processed map", AD-unabhängig.
- **Später:** ML-Segmenter für gerahmte/texturierte/fotoreale Overviews; Batch über ModHub;
  Mechet + Weipersdorf nachziehen.
- Spline-Router (R1/RoadGraph.lua) + reachable/Grid-Bake bleiben verworfen/Fallback.
