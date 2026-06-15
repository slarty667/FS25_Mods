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
